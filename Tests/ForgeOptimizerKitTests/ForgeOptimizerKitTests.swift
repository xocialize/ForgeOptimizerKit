import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo
import MediaMeasure
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

    func testRequestPipelineWritesExactOutputAndEchoesContext() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let src = tmp.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(96, 96), to: src)
        // nested + host-chosen filename → Forge must create the parent and write EXACTLY here.
        let outURL = tmp.appendingPathComponent("variants/entity-42--visually-lossless.heic")

        let req = OptimizeRequest(input: src, output: outURL,
                                  options: Options(quality: .balanced), context: "entity-42")
        var results: [OptimizeResult] = []
        for await r in forge.optimize([req]) { results.append(r) }

        let r = try XCTUnwrap(results.first)
        XCTAssertEqual(r.context, "entity-42", "the correlation token must echo back")
        XCTAssertEqual(r.outputType, .heic, "the authoritative output type surfaces (still → HEIC)")
        guard case .file(let written) = r.output else { return XCTFail("expected .file output") }
        XCTAssertEqual(written, outURL, "must write to the host-dictated exact URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    func testServiceIsSingleFlightAndRejectsWhileBusy() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let src = tmp.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(96, 96), to: src)

        let service = ForgeOptimizerService()
        let first = OptimizeRequest(input: src, output: tmp.appendingPathComponent("o1.heic"))
        let second = OptimizeRequest(input: src, output: tmp.appendingPathComponent("o2.heic"))

        // Start a run but DON'T drain it → the service stays .processing (release() is gated on draining).
        let stream1 = try await service.optimize([first])
        let busy = await service.isBusy
        XCTAssertTrue(busy)

        // A concurrent submission is rejected, not queued (host owns queueing).
        do {
            _ = try await service.optimize([second])
            XCTFail("expected ForgeError.busy")
        } catch ForgeError.busy {
            // expected
        }

        // Drain → releases the lock; a fresh submission then succeeds.
        for await _ in stream1 {}
        let idle = await service.isBusy
        XCTAssertFalse(idle)
        var count = 0
        for await _ in try await service.optimize([second]) { count += 1 }
        XCTAssertEqual(count, 1)
    }

    /// Video upscale path (V4b): `optimize` on a clip with `upscale: .x2` + an injected enhancer routes to the
    /// temporally-consistent SR pipeline → a larger HEVC deliverable, recipe records the upscale factor.
    func testVideoUpscaleProducesLargerHEVC() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fo-vup-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("clip.mp4")
        try makeClip(at: src, w: 64, h: 48, frames: 4)

        let forge = ForgeOptimizer(enhancer: DoublingEnhancer(), flowProvider: ZeroFlowProvider())
        var result: OptimizeResult?
        for await r in try forge.optimize(.url(src), to: .directory(tmp),
                                          Options(quality: .balanced, upscale: .x2)) { result = r }

        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.kind, .video)
        XCTAssertEqual(r.recipe.upscaled, 2)
        XCTAssertEqual(r.after.width, 128, "2× width")
        XCTAssertEqual(r.after.height, 96, "2× height")
        guard case .file(let out) = r.output else { return XCTFail("expected a file output") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - Fixtures

    private let forge = ForgeOptimizer()

    private func makeClip(at url: URL, w: Int, h: Int, frames: Int) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let p = base.assumingMemoryBound(to: UInt8.self)
                var seed = UInt32(truncatingIfNeeded: i &* 2654435761 | 1)
                for j in 0..<(CVPixelBufferGetBytesPerRow(buf) * h) {
                    seed = seed &* 1664525 &+ 1013904223; p[j] = UInt8(truncatingIfNeeded: seed >> 16)
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
    }

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

/// Test flow provider: zero displacement (stands in for SEA-RAFT; static-scene flow).
private struct ZeroFlowProvider: VideoFlowProvider {
    func flow(_ a: CGImage, _ b: CGImage) async throws -> DenseFlow {
        DenseFlow(width: a.width, height: a.height, uv: [Float](repeating: 0, count: a.width * a.height * 2))
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
