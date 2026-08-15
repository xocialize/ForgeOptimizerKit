import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// The opt-in bulk width (`ForgeOptimizer(bulkConcurrency:)` / `FORGE_BULK_CONCURRENCY`).
/// Contracts under test: results yield in strict submission order regardless of completion order;
/// per-item failure isolation survives concurrency; non-stills run exclusively between still
/// batches; concurrent receipts match serial receipts field-for-field (the width changes wall
/// clock, never outcomes); an injected enhancer forces serial. No timing assertions — the
/// concurrent-vs-serial wall verdict is forgebench's job on a quiet machine, not the suite's.
final class BulkConcurrencyTests: XCTestCase {

    func testWidth3PreservesSubmissionOrderAndOutcomes() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let inputs = try (0..<8).map { i -> URL in
            let u = tmp.appendingPathComponent("still-\(i).jpg")
            try writeJPEG(makeTexturedImage(96, 96, seed: UInt32(i + 1)), to: u)
            return u
        }
        let forge = ForgeOptimizer(bulkConcurrency: 3)
        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.urls(inputs), to: .directory(tmp.appendingPathComponent("o"))) {
            results.append(r)
        }
        XCTAssertEqual(results.map(\.input), inputs, "yields must follow submission order")
        for r in results {
            if case .failed(let why) = r.status { XCTFail("item failed: \(why)") }
        }
    }

    /// A junk .txt (unknown kind → the exclusive path) and a garbage .jpg (decode failure inside a
    /// concurrent batch) sit between healthy stills: both fail in isolation, order holds, and the
    /// healthy stills on every side deliver.
    func testFailureIsolationAcrossMixedSegments() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        func still(_ n: Int) throws -> URL {
            let u = tmp.appendingPathComponent("s\(n).jpg")
            try writeJPEG(makeTexturedImage(96, 96, seed: UInt32(n + 10)), to: u)
            return u
        }
        let junkTxt = tmp.appendingPathComponent("notes.txt")
        try Data("not media".utf8).write(to: junkTxt)
        let junkJpg = tmp.appendingPathComponent("broken.jpg")
        try Data(repeating: 0xAB, count: 512).write(to: junkJpg)
        let inputs = [try still(0), junkTxt, try still(1), junkJpg, try still(2)]

        let forge = ForgeOptimizer(bulkConcurrency: 3)
        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.urls(inputs), to: .directory(tmp.appendingPathComponent("o"))) {
            results.append(r)
        }
        XCTAssertEqual(results.map(\.input), inputs)
        for (i, r) in results.enumerated() {
            switch (i, r.status) {
            case (1, .failed), (3, .failed): break
            case (1, _), (3, _): XCTFail("junk item \(i) should fail, got \(r.status)")
            case (_, .failed(let why)): XCTFail("healthy still \(i) failed: \(why)")
            default: break
            }
        }
    }

    /// Width never changes outcomes: the same inputs through width 3 and width 1 produce
    /// field-identical receipts (in-process still encodes are deterministic).
    func testConcurrentReceiptsMatchSerial() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let inputs = try (0..<4).map { i -> URL in
            let u = tmp.appendingPathComponent("m\(i).jpg")
            try writeJPEG(makeTexturedImage(96, 96, seed: UInt32(i + 40)), to: u)
            return u
        }
        func collect(width: Int, sub: String) async throws -> [OptimizeResult] {
            var out: [OptimizeResult] = []
            let forge = ForgeOptimizer(bulkConcurrency: width)
            for await r in try forge.webOptimize(.urls(inputs),
                                                to: .directory(tmp.appendingPathComponent(sub))) {
                out.append(r)
            }
            return out
        }
        let serial = try await collect(width: 1, sub: "serial")
        let wide = try await collect(width: 3, sub: "wide")
        XCTAssertEqual(serial.count, wide.count)
        for (a, b) in zip(serial, wide) {
            XCTAssertEqual(a.input, b.input)
            XCTAssertEqual(a.after.bytes, b.after.bytes, "\(a.input.lastPathComponent) bytes differ")
            XCTAssertEqual(a.recipe.codec, b.recipe.codec)
            XCTAssertEqual(statusWord(a.status), statusWord(b.status))
        }
    }

    func testEnhancerForcesSerialWidth() {
        struct NoopEnhancer: ImageEnhancer {
            func enhance(_ image: CGImage, options: Options) async throws -> CGImage { image }
        }
        XCTAssertEqual(ForgeOptimizer(enhancer: NoopEnhancer(), bulkConcurrency: 4).effectiveBulkWidth, 1,
                       "engine-backed enhance keeps bulk serial until admission is measured")
        XCTAssertEqual(ForgeOptimizer(bulkConcurrency: 4).effectiveBulkWidth, 4)
        XCTAssertEqual(ForgeOptimizer(bulkConcurrency: 99).effectiveBulkWidth, 8, "clamped")
    }

    // MARK: - Fixtures (WebOptimizeTests conventions, self-contained)

    private func makeTempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func makeTexturedImage(_ w: Int, _ h: Int, seed: UInt32) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var s = seed
        func next() -> UInt8 { s = s &* 1_664_525 &+ 1_013_904_223; return UInt8((s >> 16) & 0xff) }
        for p in 0..<(w * h) {
            let gx = UInt8((p % w) * 255 / max(1, w - 1))
            buf[p * 4] = gx &+ (next() & 0x1f)
            buf[p * 4 + 1] = next()
            buf[p * 4 + 2] = 255 &- gx
            buf[p * 4 + 3] = 255
        }
        return ctx.makeImage()!
    }

    private func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.6) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                         1, nil) else {
            throw NSError(domain: "test", code: 1)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 2) }
    }

    private func statusWord(_ s: Status) -> String {
        switch s {
        case .optimized: return "optimized"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
}
