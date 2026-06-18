import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// Phase-A headless coverage: the image happy path (analyze → optimize → conform) against
/// media-bridge. Small (128²) gradient keeps the SSIMULACRA2-guided search cheap (LESSONS.md).
final class ForgeOptimizerKitTests: XCTestCase {

    func testImageAnalyzeOptimizeConform() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let img = makeGradientImage(128, 128)
        let src = tmp.appendingPathComponent("input.png")
        try writePNG(img, to: src)

        let forge = ForgeOptimizer()

        // analyze — structural, read-only
        var analyses: [Analysis] = []
        for await a in forge.analyze(.url(src)) { analyses.append(a) }
        XCTAssertEqual(analyses.count, 1)
        let analysis = try XCTUnwrap(analyses.first)
        XCTAssertEqual(analysis.kind, .image)
        XCTAssertEqual(analysis.width, 128)
        XCTAssertEqual(analysis.height, 128)
        XCTAssertEqual(analysis.codecID, "png")
        XCTAssertEqual(analysis.recommendation.codec, "HEIC")
        XCTAssertNil(analysis.qualityScore)                 // structural tier has no score

        // optimize — target-quality HEIC
        let outDir = tmp.appendingPathComponent("out")
        var results: [OptimizeResult] = []
        for await r in try forge.optimize(.url(src), to: .directory(outDir),
                                          Options(quality: .balanced)) {
            results.append(r)
        }
        XCTAssertEqual(results.count, 1)
        let r = try XCTUnwrap(results.first)
        XCTAssertEqual(r.kind, .image)
        let score = try XCTUnwrap(r.after.qualityScore)
        XCTAssertGreaterThan(score, 70, "should clear a reasonable perceptual floor")
        if case .file(let outURL) = r.output {              // a gradient should compress below PNG
            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
            XCTAssertEqual(outURL.pathExtension, "heic")
            if case .optimized = r.status {} else { XCTFail("expected .optimized, got \(r.status)") }
        }

        // conform — exact / fit / fill
        let exact = try forge.conform(img, to: MediaSpec(size: .exact(width: 64, height: 32)))
        XCTAssertEqual(exact.width, 64)
        XCTAssertEqual(exact.height, 32)

        let fit = try forge.conform(img, to: MediaSpec(size: .fit(maxWidth: 64, maxHeight: 64)))
        XCTAssertEqual(fit.width, 64)                        // square source → fits to 64×64
        XCTAssertEqual(fit.height, 64)

        let fill = try forge.conform(img, to: MediaSpec(size: .fill(width: 50, height: 70)))
        XCTAssertEqual(fill.width, 50)
        XCTAssertEqual(fill.height, 70)
    }

    func testBulkIsolatesPerItemFailure() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let good = tmp.appendingPathComponent("good.png")
        try writePNG(makeGradientImage(96, 96), to: good)
        let bad = tmp.appendingPathComponent("missing.png")   // does not exist → per-item failure

        var results: [OptimizeResult] = []
        for await r in try forge.optimizeStream([good, bad], into: tmp.appendingPathComponent("o")) {
            results.append(r)
        }
        XCTAssertEqual(results.count, 2, "bad item must not abort the run")
        XCTAssertTrue(results.contains { if case .failed = $0.status { return true }; return false })
    }

    func testEnhanceSeamRunsBeforeEncode() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let src = tmp.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(96, 96), to: src)
        let out = tmp.appendingPathComponent("out")

        // enhance ON + an enhancer that doubles dimensions → it runs, the upscaled image flows into
        // encode (after.width == 192), recipe records restore + upscale.
        let forge = ForgeOptimizer(enhancer: DoublingEnhancer())
        var on: [OptimizeResult] = []
        for await r in try forge.optimize(.url(src), to: .directory(out),
                                          Options(quality: .balanced, enhance: .on, upscale: .x2)) {
            on.append(r)
        }
        let r = try XCTUnwrap(on.first)
        XCTAssertEqual(r.after.width, 192)
        XCTAssertEqual(r.after.height, 192)
        XCTAssertTrue(r.recipe.restored)
        XCTAssertEqual(r.recipe.upscaled, 2)

        // enhance OFF → the enhancer is NOT applied (dims unchanged, recipe.restored == false).
        let off = ForgeOptimizer(enhancer: DoublingEnhancer())
        var offResults: [OptimizeResult] = []
        for await r in try off.optimize(.url(src), to: .directory(out),
                                        Options(quality: .balanced, enhance: .off)) {
            offResults.append(r)
        }
        let r2 = try XCTUnwrap(offResults.first)
        XCTAssertEqual(r2.after.width, 96)
        XCTAssertFalse(r2.recipe.restored)
    }

    // MARK: - Fixtures

    private let forge = ForgeOptimizer()

    private func makeGradientImage(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorsSpace: cs,
                              colors: [CGColor(red: 0.10, green: 0.20, blue: 0.85, alpha: 1),
                                       CGColor(red: 0.95, green: 0.70, blue: 0.10, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return ctx.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ForgeError.renderFailed("png destination")
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { throw ForgeError.renderFailed("png finalize") }
    }
}

private extension ForgeOptimizer {
    /// Test convenience: optimize a URL list into a directory.
    func optimizeStream(_ urls: [URL], into dir: URL) throws -> AsyncStream<OptimizeResult> {
        try optimize(.urls(urls), to: .directory(dir))
    }
}

/// Test enhancer: doubles the image dimensions (stands in for an engine restore/upscale).
private struct DoublingEnhancer: ImageEnhancer {
    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        let w = image.width * 2, h = image.height * 2
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
