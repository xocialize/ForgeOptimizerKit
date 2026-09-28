import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// BRIDGE-062. The receipt used to report `options.upscale` — what the caller *asked for*. That is
/// accurate only while every model honours every request, which is a property of today's models rather
/// than of the code.
///
/// BRIDGE-040 is the case that proves it: a fixed-4× model asked for 2× produced 4× pixels while the
/// receipt said 2×. These lock the fix by driving the exact divergences a request-based tag cannot see.
final class UpscaleHonestyTests: XCTestCase {

    private func recipe(from before: Int, to after: Int, requested: UpscaleFactor) -> AppliedRecipe {
        var r = AppliedRecipe()
        r.setUpscale(measuredFrom: before, to: after, requested: requested)
        return r
    }

    func testHonouredRequestReportsTheFactorWithNoNoise() {
        let r = recipe(from: 512, to: 1024, requested: .x2)
        XCTAssertEqual(r.upscaled, 2)
        XCTAssertNil(r.upscaleRequested, "no divergence to report when the model did as asked")
        XCTAssertTrue(r.description.contains("upscale×2"))
        XCTAssertFalse(r.description.contains("asked"))
    }

    /// The original BRIDGE-040 defect: asked 2×, got 4×. The receipt must say 4 and show the divergence.
    func testFixedFourTimesModelAskedForTwoReportsFourAndSaysSo() {
        let r = recipe(from: 512, to: 2048, requested: .x2)
        XCTAssertEqual(r.upscaled, 4, "must report the pixels that exist, not the request")
        XCTAssertEqual(r.upscaleRequested, 2)
        XCTAssertTrue(r.description.contains("upscale×4 (asked ×2)"), r.description)
    }

    /// The inverse lie: an upscale was requested and did not happen. Reporting the request here would
    /// claim an enhancement that is not in the file.
    func testRequestedButNotAppliedReportsNoUpscale() {
        let r = recipe(from: 512, to: 512, requested: .x2)
        XCTAssertNil(r.upscaled, "no upscale in the pixels means no upscale in the receipt")
        XCTAssertEqual(r.upscaleRequested, 2, "but the unmet request is still surfaced")
        XCTAssertFalse(r.description.contains("upscale×"), r.description)
    }

    func testNoUpscaleRequestedAndNoneApplied() {
        let r = recipe(from: 512, to: 512, requested: .none)
        XCTAssertNil(r.upscaled)
        XCTAssertNil(r.upscaleRequested)
    }

    /// Degenerate input must not fabricate a factor.
    func testZeroWidthsDoNotInventAnUpscale() {
        XCTAssertNil(recipe(from: 0, to: 1024, requested: .x2).upscaled)
        XCTAssertNil(recipe(from: 512, to: 0, requested: .x2).upscaled)
    }

    /// Rounding tolerance: an encoder nudging 1024→1026 for macroblock alignment is not a 1× upscale
    /// claim, and a real 2× that lands a pixel off is still 2×.
    func testToleratesAlignmentNudgesWithoutMisreporting() {
        XCTAssertNil(recipe(from: 1024, to: 1026, requested: .none).upscaled)
        XCTAssertEqual(recipe(from: 512, to: 1023, requested: .x2).upscaled, 2)
    }

    // MARK: - Through the call sites, not just the helper

    // The tests above drive `setUpscale` directly. Every other end-to-end upscale test uses a model
    // that honours ×2, where request and result agree — so a call site regressing to
    // `options.upscale` would pass all of them. These drive the divergence through `optimize` /
    // `webOptimize` and hold the receipt to the delivered file, never to the Kit's own bookkeeping.

    /// The corpus case (AB-T-0013): a real signage still, a model that returns 4× when asked for 2×.
    /// `FORGE_CORPUS` unset → skip, per the corpus README (media-bridge's corpus harness does the same).
    ///
    ///   FORGE_CORPUS=/…/training-resources/Corpus swift test --filter UpscaleHonestyTests
    func testCorpusStillAskedForTwoGotFourReceiptsFour() async throws {
        guard let corpus = ProcessInfo.processInfo.environment["FORGE_CORPUS"], !corpus.isEmpty else {
            throw XCTSkip("FORGE_CORPUS unset — corpus case skipped")
        }
        let src = URL(fileURLWithPath: corpus).appendingPathComponent("derived/320/stills/KEYNOTE_graphic.png")
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("no \(src.path)") }
        try await assertStillAskedForTwoReceiptsFour(src)
    }

    /// The same still divergence on a synthetic image, so CI — which has no corpus — locks it too.
    func testStillAskedForTwoGotFourReceiptsFour() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(64, 48), to: src)
        try await assertStillAskedForTwoReceiptsFour(src)
    }

    /// Both video call sites: native (the SR pipeline's HEVC is the deliverable) and web (that
    /// intermediate re-encoded to H.264). Each must measure the file it delivered.
    func testVideoAskedForTwoGotFourReceiptsFourOnBothProfiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeGradientClip(to: src, w: 64, h: 48, frames: 4)
        let forge = ForgeOptimizer(enhancer: FixedScaleEnhancer(factor: 4), flowProvider: ZeroFlowProvider())
        let ask = Options(quality: .aggressive, upscale: .x2)

        for profile in ["native", "web"] {
            let out = dir.appendingPathComponent(profile)
            let stream = profile == "web"
                ? try forge.webOptimize(.url(src), to: .directory(out), ask)
                : try forge.optimize(.url(src), to: .directory(out), ask)
            var result: OptimizeResult?
            for await r in stream { result = r }
            let r = try XCTUnwrap(result, profile)
            guard case .file(let delivered) = r.output else {
                XCTFail("\(profile): expected a delivered file, got \(r.status)"); continue
            }
            let track = try await AVURLAsset(url: delivered).loadTracks(withMediaType: .video).first
            let size = try await XCTUnwrap(track, profile).load(.naturalSize)
            XCTAssertEqual(Int(size.width), 4 * 64, "\(profile): the model returned 4×, whatever was asked")
            XCTAssertEqual(Int(size.height), 4 * 48, profile)
            XCTAssertEqual(r.recipe.upscaled, 4, "\(profile): the tag follows the file")
            XCTAssertEqual(r.recipe.upscaleRequested, 2, "\(profile): the unhonoured request stays visible")
            XCTAssertTrue(String(describing: r.recipe).contains("upscale×4 (asked ×2)"), "\(profile): \(r.recipe)")
        }
    }

    /// `optimize` with the fixed-4× model asked for ×2, then the deliverable read back: the receipt —
    /// struct, prose and NDJSON — must describe what is in the file.
    private func assertStillAskedForTwoReceiptsFour(_ src: URL) async throws {
        let out = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let forge = ForgeOptimizer(enhancer: FixedScaleEnhancer(factor: 4))
        var results: [OptimizeResult] = []
        for await r in try forge.optimize(.url(src), to: .directory(out),
                                          Options(quality: .balanced, enhance: .on, upscale: .x2)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status, case .file(let delivered) = r.output else {
            return XCTFail("expected a delivered file, got \(r.status)")
        }

        // Both ends measured from the files themselves: the one witness that cannot be wrong.
        let source = try pixelSize(src), result = try pixelSize(delivered)
        XCTAssertEqual(result.w, 4 * source.w, "the model returned 4×, whatever was asked")
        XCTAssertEqual(result.h, 4 * source.h)
        XCTAssertEqual(r.after.width, result.w)
        XCTAssertEqual(r.after.height, result.h)

        XCTAssertEqual(r.recipe.upscaled, 4, "the tag follows the pixels")
        XCTAssertEqual(r.recipe.upscaleRequested, 2, "the unhonoured request stays visible")
        XCTAssertTrue(String(describing: r.recipe).contains("upscale×4 (asked ×2)"), "\(r.recipe)")

        // The NDJSON a host ingests says the same — checked after serialization, not before it.
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(r)))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let recipe = try XCTUnwrap(parsed["recipe"] as? String)
        XCTAssertTrue(recipe.contains("upscale×4 (asked ×2)"), recipe)
        let after = try XCTUnwrap(parsed["after"] as? [String: Any])
        XCTAssertEqual(after["width"] as? Int, result.w)
        XCTAssertEqual(after["height"] as? Int, result.h)
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pixelSize(_ url: URL) throws -> (w: Int, h: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ForgeError.decodeFailed(url)
        }
        return (w, h)
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

    private func writeGradientClip(to url: URL, w: Int, h: Int, frames: Int) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let o = y * rowBytes + x * 4
                    p[o] = UInt8((x * 255 / w + i * 6) % 256)
                    p[o + 1] = UInt8(y * 255 / h)
                    p[o + 2] = UInt8((x + y) * 255 / (w + h))
                    p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        guard writer.status == .completed else {
            throw ForgeError.renderFailed("fixture writer: \(String(describing: writer.error))")
        }
    }
}

/// A model that ignores the requested scale and returns `factor`× pixels — BRIDGE-040's shape
/// (Real-ESRGAN `general` did exactly this, BRIDGE-029). The receipt has to follow the pixels.
struct FixedScaleEnhancer: ImageEnhancer {
    let factor: Int

    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        let w = image.width * factor, h = image.height * factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
