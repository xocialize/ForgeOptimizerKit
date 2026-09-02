import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ForgeOptimizerKit
@testable import MediaMeasure

/// Two promises this Kit makes about content it must not quietly reinterpret (AB-A-0055).
///
/// 1. **Alpha video is refused, not flattened.** Every video deliverable here is HEVC- or
///    H.264-in-mp4 and no mp4 configuration carries alpha, so an alpha source would come out
///    opaque — with a large, entirely fake byte "win" and a quality score that cannot object.
/// 2. **The consumer camera self-gate can be kept off.** It is the planner's only floor-LOWERING
///    device, and on rendered content its denoised reference softens the text edges that content
///    exists to show.
final class AlphaAndCameraGateTests: XCTestCase {

    private let forge = ForgeOptimizer()
    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func scratchDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-alpha-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        scratch.append(u)
        return u
    }

    private func scratchURL(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-alpha-\(UUID().uuidString).\(ext)")
        scratch.append(u)
        return u
    }

    /// Run one item through a verb and return its single result — the bulk API is an
    /// `AsyncStream`, and every case here is a one-file case.
    private func one(_ stream: AsyncStream<OptimizeResult>) async throws -> OptimizeResult {
        var results: [OptimizeResult] = []
        for await r in stream { results.append(r) }
        XCTAssertEqual(results.count, 1)
        return try XCTUnwrap(results.first)
    }

    // MARK: - Fixtures

    /// A still with REAL transparency: transparent ground, an opaque disc, a half-transparent bar.
    private func makeTransparentPNG() throws -> URL {
        let w = 256, h = 192
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 8))
        let url = scratchURL("png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeAlphaMOV(_ codec: AlphaVideoWriter.Codec) async throws -> URL {
        let url = scratchURL("mov")
        let w = 96, h = 64
        var remaining = 12
        _ = try await AlphaVideoWriter.write(to: url, codec: codec, width: w, height: h, frameRate: 30) {
            guard remaining > 0 else { return nil }
            remaining -= 1
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h {
                for x in 0..<w {
                    let a: UInt8 = x < w / 2 ? 255 : 40
                    let i = y * stride + x * 4
                    base[i] = a; base[i + 1] = a; base[i + 2] = a; base[i + 3] = a
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            return (buf, nil)
        }
        return url
    }

    /// Does any pixel of the delivered still still carry a < 255 alpha?
    private func translucentPixels(_ url: URL) throws -> Int {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(cg.alphaInfo)
        else { return 0 }               // no channel at all → flattened
        let w = cg.width, h = cg.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in 0..<h { for x in 0..<w where base[y * ctx.bytesPerRow + x] < 255 { count += 1 } }
        return count
    }

    // MARK: - Stills: alpha SURVIVES into HEIC

    /// The positive half of the alpha answer. HEIC carries alpha, and `optimize` keeps it — so a
    /// transparent still is a normal optimize, not a refusal. Asserted on the delivered bytes,
    /// because the scorer cannot see alpha and would not notice if this broke.
    func testTransparentStillKeepsAlphaThroughHEIC() async throws {
        let input = try makeTransparentPNG()
        let out = scratchDir()
        let r = try await one(try forge.optimize(.url(input), to: .directory(out), Options()))

        guard case .file(let delivered) = r.output else {
            return XCTFail("expected a delivered HEIC, got \(r.status)")
        }
        XCTAssertEqual(r.outputType, UTType.heic)
        XCTAssertGreaterThan(try translucentPixels(delivered), 1000,
                             "HEIC must carry the alpha channel through optimize, not flatten it")
    }

    // MARK: - Video: alpha is REFUSED

    /// ProRes 4444 under the native (HEVC) profile. Before this refusal the fixture "optimized"
    /// with a huge byte win, most of it the discarded alpha channel, and reported success.
    func testProRes4444IsRefusedRatherThanFlattened() async throws {
        let input = try await makeAlphaMOV(.proRes4444)
        let out = scratchDir()
        let r = try await one(try forge.optimize(.url(input), to: .directory(out), Options()))

        guard case .skipped(let why) = r.status else {
            return XCTFail("alpha video must be skipped, not \(r.status)")
        }
        XCTAssertTrue(why.contains("alpha"), "the skip must name alpha as the reason: \(why)")
        if case .none = r.output {} else { XCTFail("a refusal must deliver no file") }
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty) ?? false,
                      "a refusal must not leave an output behind")
    }

    /// HEVC-with-alpha `.mov` — same codec family as the deliverable, so only the container and
    /// the alpha plane differ. It must be refused for the same reason.
    func testHEVCWithAlphaIsRefusedRatherThanFlattened() async throws {
        let input = try await makeAlphaMOV(.hevcWithAlpha)
        let r = try await one(try forge.optimize(.url(input), to: .directory(scratchDir()), Options()))
        guard case .skipped(let why) = r.status else {
            return XCTFail("alpha video must be skipped, not \(r.status)")
        }
        XCTAssertTrue(why.contains("alpha"))
    }

    /// The web verb converts to H.264, which has no alpha either — the refusal is not native-only.
    func testWebOptimizeAlsoRefusesAlphaVideo() async throws {
        let input = try await makeAlphaMOV(.hevcWithAlpha)
        let r = try await one(try forge.webOptimize(.url(input), to: .directory(scratchDir()), Options()))
        guard case .skipped(let why) = r.status else {
            return XCTFail("alpha video must be skipped, not \(r.status)")
        }
        XCTAssertTrue(why.contains("alpha"))
    }

    // MARK: - The camera self-gate policy

    /// Pure policy — no encode, no probe. The asymmetry between `.graphic` and `.general` is the
    /// load-bearing part: `.general` INCLUDES camera footage, which is the gate's whole purpose.
    func testCameraGatePolicy() {
        XCTAssertTrue(ForgeOptimizer.cameraGateAllowed(Options(quality: .consumer)),
                      "default is unchanged: the gate still runs")
        XCTAssertFalse(ForgeOptimizer.cameraGateAllowed(Options(quality: .consumer, cameraGate: .off)),
                       "an explicit policy must turn the gate off")
        XCTAssertFalse(ForgeOptimizer.cameraGateAllowed(Options(quality: .consumer, contentClass: .graphic)),
                       "rendered content is definitionally not camera capture")
        XCTAssertTrue(ForgeOptimizer.cameraGateAllowed(Options(quality: .consumer, contentClass: .general)),
                      ".general includes handheld footage — the content the gate exists for")
    }

    /// A stated `.graphic` class must reach the search as the RAISED class floor. Before the
    /// suppression a fired gate outranked it and took consumer's graphic floor from 90 down to 70,
    /// scored against a softened reference — a stated class weakening its own promise.
    func testGraphicClassKeepsItsRaisedFloorUnderConsumer() {
        XCTAssertEqual(ContentClassifier.raisedFloor(preset: .consumer, class: .graphic), 90)
        XCTAssertNil(ContentClassifier.raisedFloor(preset: .consumer, class: .general))
    }
}
