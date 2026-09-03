import AVFoundation
import CoreVideo
import XCTest
@testable import ForgeOptimizerKit

/// `Options.secondary` — a weaker-floor rendition beside the primary, harvested from the search
/// that already ran (AB-A-0059).
///
/// The mechanism lives in media-bridge (`VideoSecondaryFloorTests` covers the harvest itself). What
/// the Kit owes on top of it is *pairing and honesty*:
///
/// · the rendition and the primary come from ONE search — the Kit may run two (hint over-reach, the
///   class ratchet), and a mixed pair would put a receipt on a combination that never existed;
/// · a request that reaches a route with no answer is still ANSWERED, so "nothing qualified" and
///   "this path does not do that" are never the same silence;
/// · the receipt says `harvested`, not `optimized at N` — the whole reason the ask was written the
///   way it was.
final class SecondaryRenditionTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func scratchURL(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-secondary-\(UUID().uuidString).\(ext)")
        scratch.append(u)
        return u
    }

    private func scratchDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-secondary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        scratch.append(u)
        return u
    }

    private func first(_ stream: AsyncStream<OptimizeResult>) async throws -> OptimizeResult {
        for await r in stream { return r }
        throw XCTSkip("the stream yielded nothing")
    }

    // MARK: - The deliverable

    /// The keynote row of AB-A-0059: a floor the clip cannot reach, so `optimize` ships nothing —
    /// and the weaker rung, which the same search already encoded, is the only thing that ships.
    ///
    /// The two floors are `.custom` values chosen relative to what a synthetic clip can do, not the
    /// product's 90/80: absolute scores are content-dependent, and pinning them here would test the
    /// fixture rather than the Kit.
    func testUnreachableFloorStillShipsTheHarvestedRendition() async throws {
        let forge = ForgeOptimizer()
        let source = try makeGradientClip()
        let outDir = try scratchDir()
        let secondaryURL = outDir.appendingPathComponent("wifi.mp4")

        let r = try await first(try forge.optimize(
            .url(source), to: .directory(outDir),
            Options(quality: .custom(96),
                    secondary: SecondaryRendition(floor: 40, output: secondaryURL))))

        guard case .skipped = r.status else {
            throw XCTSkip("fixture check: floor 96 was reachable here, so there is no skip to test")
        }
        if case .none = r.output {} else { XCTFail("a skipped primary must leave no output") }

        let sec = try XCTUnwrap(r.secondary, "the search encoded a floor-40 file — it must ship")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondaryURL.path))
        XCTAssertEqual(sec.bytes, fileSize(secondaryURL))
        XCTAssertLessThan(sec.bytes, r.before.bytes)
        XCTAssertGreaterThanOrEqual(sec.score, 40)
        XCTAssertEqual(sec.floor, 40)
        XCTAssertEqual(sec.searchFloor, 96, "the receipt names the search this fell out of")
        if case .file(let u) = sec.output { XCTAssertEqual(u, secondaryURL) } else { XCTFail("expected a file") }

        // The honesty point of the ask, pinned: the rendition may never claim a floor-40 SEARCH.
        XCTAssertEqual(sec.provenance, "harvested @SSIMU2≥40 (from the ≥96 search)")
        XCTAssertEqual(sec.overshoot, sec.score - sec.floor, accuracy: 0.0001,
                       "overshoot is what tells a caller whether the free version was good enough")
        XCTAssertEqual(r.recipe.secondaryOutcome, "delivered")
        XCTAssertEqual(r.recipe.secondaryFloor, 40)
        XCTAssertTrue(String(describing: r.recipe).contains("harvested"),
                      "the human receipt must say harvested, not just print a floor: \(r.recipe)")

        // A per-frame aggregation rides along, exactly as the primary's does — a video score is a
        // percentile over a sample and a bare number cannot say so (BRIDGE-061).
        XCTAssertEqual(sec.aggregation.percentile, 10)
        XCTAssertGreaterThan(sec.aggregation.framesScored, 0)
    }

    /// The secondary is a second artifact, not a smaller primary: it must not move the numbers that
    /// describe what happened to the SOURCE. A skipped item still counts at `before.bytes` in the
    /// aggregate — otherwise a bulk run would report savings for a file it declined to replace.
    func testTheRenditionNeverCountsAsSavingsForTheSource() async throws {
        let forge = ForgeOptimizer()
        let source = try makeGradientClip()
        let outDir = try scratchDir()

        let r = try await first(try forge.optimize(
            .url(source), to: .directory(outDir),
            Options(quality: .custom(96),
                    secondary: SecondaryRendition(floor: 40,
                                                  output: outDir.appendingPathComponent("wifi.mp4")))))
        try XCTSkipUnless(r.secondary != nil, "fixture check: needs a delivered rendition")
        guard case .skipped = r.status else { throw XCTSkip("fixture check: needs a skipped primary") }

        XCTAssertEqual(r.after.bytes, r.before.bytes,
                       "the original is what stands — `after` must describe IT, not the rendition")
        XCTAssertEqual(r.savedBytes, 0)
        let summary = Summary([r])
        XCTAssertEqual(summary.bytesOut, summary.bytesIn,
                       "a skip saves nothing on the source no matter what shipped beside it")
        XCTAssertEqual(summary.skipped, 1)
    }

    // MARK: - Requests that reach a route with no answer

    /// A still is answered, not ignored. `video-only` beats silence: a host that asked and got
    /// nothing back has to be able to tell a policy from a failure.
    func testAStillAnswersTheRequestRatherThanIgnoringIt() async throws {
        let forge = ForgeOptimizer()
        let source = try makePNG()
        let outDir = try scratchDir()
        let secondaryURL = outDir.appendingPathComponent("wifi.mp4")

        let r = try await first(try forge.optimize(
            .url(source), to: .directory(outDir),
            Options(secondary: SecondaryRendition(floor: 40, output: secondaryURL))))

        XCTAssertNil(r.secondary)
        XCTAssertEqual(r.recipe.secondaryOutcome, "video-only")
        XCTAssertEqual(r.recipe.secondaryFloor, 40)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondaryURL.path),
                       "an unanswerable request writes nothing")
    }

    /// A floor at or above the preset's cannot produce a rendition — everything that clears it is
    /// the primary or larger — and the refusal is reported as such rather than as an absence.
    func testAFloorAboveThePresetIsRefusedNotSilentlyDropped() async throws {
        let forge = ForgeOptimizer()
        let source = try makeGradientClip()
        let outDir = try scratchDir()
        let secondaryURL = outDir.appendingPathComponent("wifi.mp4")

        let r = try await first(try forge.optimize(
            .url(source), to: .directory(outDir),
            Options(quality: .custom(60),
                    secondary: SecondaryRendition(floor: 99, output: secondaryURL))))

        XCTAssertNil(r.secondary)
        XCTAssertEqual(r.recipe.secondaryFloor, 99)
        XCTAssertNotNil(r.recipe.secondaryOutcome, "the request must be answered either way")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondaryURL.path))
    }

    /// No request → no receipt noise. A recipe that mentions a secondary on every item would make
    /// the field useless for spotting the ones that actually asked.
    func testNoRequestLeavesNoTrace() async throws {
        let forge = ForgeOptimizer()
        let r = try await first(try forge.optimize(.url(try makeGradientClip()),
                                                   to: .directory(try scratchDir()),
                                                   Options(quality: .custom(60))))
        XCTAssertNil(r.secondary)
        XCTAssertNil(r.recipe.secondaryFloor)
        XCTAssertNil(r.recipe.secondaryOutcome)
        XCTAssertFalse(String(describing: r.recipe).contains("harvested"))
    }

    // MARK: - Fixtures

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// Smooth drifting gradient with a little detail — compressible enough to have a real candidate
    /// ladder, textured enough that a 96 floor is out of reach. Same reasoning as
    /// `WebOptimizeTests.makeGradientClip`.
    private func makeGradientClip(w: Int = 320, h: Int = 240, frames: Int = 50) throws -> URL {
        let url = scratchURL("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]])
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
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buf)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h { for x in 0..<w {
                let o = y * stride + x * 4
                base[o] = UInt8((x &+ i &* 3) & 0xFF)
                base[o + 1] = UInt8((y &+ i &* 2) & 0xFF)
                base[o + 2] = UInt8((((x &* y) >> 3) &+ i &* 5) & 0xFF)
                base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 25))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        XCTAssertEqual(writer.status, .completed, "fixture writer: \(String(describing: writer.error))")
        return url
    }

    private func makePNG(w: Int = 64, h: Int = 64) throws -> URL {
        let url = scratchURL("png")
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            pixels[o] = UInt8(x * 4 % 256); pixels[o + 1] = UInt8(y * 4 % 256)
            pixels[o + 2] = 128; pixels[o + 3] = 255
        } }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }
}
