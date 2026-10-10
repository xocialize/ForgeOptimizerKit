import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// `UpscaleTier.liveAction` — the whole-clip video tier behind the `VideoUpscaler` seam (ForgeCore: FlashVSR).
///
/// What these pin: the tier routes to the video upscaler and NEVER to the per-frame enhancer, on both profiles; a
/// missing or refusing upscaler fails the item with its reason (no per-frame stand-in); the upscaler is asked with
/// the clip's own size; the source's audio comes back although the upscaler writes video only; the receipt names
/// what the upscaler reported and measures the factor and codec from the delivered file; a still cannot take it.
final class LiveActionUpscaleTests: XCTestCase {

    private let ask = Options(quality: .aggressive, upscale: .x4, upscaleTier: .liveAction)

    func testTierIsVideoOnlyAndSpelledForReceipts() {
        XCTAssertTrue(UpscaleTier.liveAction.isVideoOnly)
        XCTAssertFalse(UpscaleTier.fast.isVideoOnly)
        XCTAssertFalse(UpscaleTier.best.isVideoOnly)
        XCTAssertEqual(UpscaleTier.liveAction.rawValue, "live-action")
    }

    /// The route, end to end on both profiles: the upscaler ran once per item, the enhancer never, and every
    /// receipt surface names the reported backer.
    func testLiveActionRoutesToTheVideoUpscalerAndNeverTheEnhancer() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 8, audio: false)
        let enhancer = TieredEnhancer()
        let upscaler = FakeVideoUpscaler()
        let forge = ForgeOptimizer(enhancer: enhancer, flowProvider: ZeroFlowProvider(), videoUpscaler: upscaler)

        for profile in ["native", "web"] {
            let r = try await run(forge, src, into: dir.appendingPathComponent(profile), web: profile == "web")
            guard case .optimized = r.status, case .file(let delivered) = r.output else {
                XCTFail("\(profile): expected a delivered file, got \(r.status)"); continue
            }
            let size = try await videoSize(delivered)
            XCTAssertEqual(size.w, 4 * 64, profile)
            XCTAssertEqual(size.h, 4 * 48, profile)
            XCTAssertEqual(r.recipe.upscaled, 4, "\(profile): measured from the file")
            XCTAssertEqual(r.recipe.upscaleTier, .liveAction, profile)
            XCTAssertEqual(r.recipe.upscaleModel, "FakeVSR", profile)
            XCTAssertNil(r.recipe.upscaleTierRequested, profile)
            XCTAssertEqual(r.recipe.codec, profile == "web" ? "H.264" : "HEVC", "\(profile): the codec in the file")
            XCTAssertTrue(String(describing: r.recipe).contains("upscale×4 [live-action · FakeVSR]"),
                          "\(profile): \(r.recipe)")
            let parsed = try parsedReceipt(r)
            XCTAssertEqual(parsed["upscale_tier"] as? String, "live-action", profile)
            XCTAssertEqual(parsed["upscale_model"] as? String, "FakeVSR", profile)
        }
        XCTAssertEqual(upscaler.calls.count, 2, "one whole-clip call per item")
        XCTAssertEqual(enhancer.calls.count, 0, "no frame went through the per-frame enhancer")
    }

    /// The upscaler writes video only; the deliverable must still carry the source's soundtrack, on both profiles.
    func testSourceAudioComesBackOnBothProfiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 15, audio: true)
        let srcAudio = try await AVURLAsset(url: src).loadTracks(withMediaType: .audio)
        XCTAssertEqual(srcAudio.count, 1, "fixture carries audio")
        let forge = ForgeOptimizer(videoUpscaler: FakeVideoUpscaler())

        for profile in ["native", "web"] {
            let r = try await run(forge, src, into: dir.appendingPathComponent(profile), web: profile == "web")
            guard case .file(let delivered) = r.output else {
                XCTFail("\(profile): expected a delivered file, got \(r.status)"); continue
            }
            let asset = AVURLAsset(url: delivered)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1, "\(profile): the source's audio track came back")
            if let track = audio.first {
                let range = try await track.load(.timeRange)
                XCTAssertGreaterThan(range.duration.seconds, 0.3, "\(profile): real audio, not an empty track")
            }
            let video = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(video.count, 1, profile)
        }
    }

    /// LPCM in a `.mov` cannot ride in an mp4 as-is: the mux encodes it to AAC rather than dropping it.
    func testLinearPCMFromAMovIsEncodedToAACRatherThanDropped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mov")
        try writeClip(to: src, w: 64, h: 48, frames: 15, audio: true, pcmMov: true)
        let srcFormat = try await AVURLAsset(url: src).loadTracks(withMediaType: .audio).first?
            .load(.formatDescriptions).first
        XCTAssertEqual(srcFormat.map { CMFormatDescriptionGetMediaSubType($0) }, kAudioFormatLinearPCM, "fixture is LPCM")

        let r = try await run(ForgeOptimizer(videoUpscaler: FakeVideoUpscaler()), src,
                              into: dir.appendingPathComponent("out"), web: false)
        guard case .file(let delivered) = r.output else { return XCTFail("expected a delivered file, got \(r.status)") }
        let audio = try await AVURLAsset(url: delivered).loadTracks(withMediaType: .audio)
        let format = try await audio.first?.load(.formatDescriptions).first
        XCTAssertEqual(format.map { CMFormatDescriptionGetMediaSubType($0) }, kAudioFormatMPEG4AAC)
    }

    /// No video upscaler attached: the item fails, saying so — the per-frame enhancer that IS attached never stands in.
    func testWithoutAVideoUpscalerTheItemFailsAndNoFrameIsEnhanced() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 4, audio: false)
        let enhancer = TieredEnhancer()
        let forge = ForgeOptimizer(enhancer: enhancer, flowProvider: ZeroFlowProvider())
        let out = dir.appendingPathComponent("out")
        let r = try await run(forge, src, into: out, web: false)
        guard case .failed(let why) = r.status else { return XCTFail("expected a failed item, got \(r.status)") }
        XCTAssertEqual(why, "upscale tier 'live-action' unavailable: no video upscaler is attached to this optimizer")
        XCTAssertEqual(enhancer.calls.count, 0)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).isEmpty)
    }

    /// A refusal carries the upscaler's own reason, is asked with THIS clip's size and factor, and runs nothing.
    func testRefusalCarriesTheUpscalersReasonAskedWithTheClipsSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 4, audio: false)
        let upscaler = FakeVideoUpscaler(refusal: "FakeVSR needs 22.6 GB; the budget is 12.7 GB")
        let forge = ForgeOptimizer(videoUpscaler: upscaler)
        let r = try await run(forge, src, into: dir.appendingPathComponent("out"), web: false)
        guard case .failed(let why) = r.status else { return XCTFail("expected a failed item, got \(r.status)") }
        XCTAssertEqual(why, "upscale tier 'live-action' unavailable: FakeVSR needs 22.6 GB; the budget is 12.7 GB")
        XCTAssertEqual(upscaler.calls.count, 0, "refused before the upscale ran")
        let asked = upscaler.asked.all
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.w, 64)
        XCTAssertEqual(asked.first?.h, 48)
        XCTAssertEqual(asked.first?.factor, 4)
    }

    /// Without an upscale the tier asks nothing: a plain optimize under `.liveAction` is an ordinary optimize.
    func testNoUpscaleMeansNoTierQuestion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 4, audio: false)
        let upscaler = FakeVideoUpscaler(refusal: "would refuse")
        let forge = ForgeOptimizer(videoUpscaler: upscaler)
        var result: OptimizeResult?
        for await r in try forge.optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                                          Options(quality: .aggressive, upscaleTier: .liveAction)) { result = r }
        let r = try XCTUnwrap(result)
        if case .failed(let why) = r.status { XCTFail("no upscale asked, yet failed: \(why)") }
        XCTAssertTrue(upscaler.asked.all.isEmpty)
        XCTAssertNil(r.recipe.upscaleTier)
    }

    /// The upscale's frame count reaches the item's progress detail as the model emits frames.
    func testProgressCountsFramesAsTheyAreEmitted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 6, audio: false)
        let log = Lines()
        let forge = ForgeOptimizer(videoUpscaler: FakeVideoUpscaler())
        for await _ in try forge.optimize(.url(src), to: .directory(dir.appendingPathComponent("out")), ask,
                                          progress: { p in if let d = p.detail { log.add(d) } }) {}
        let lines = log.all
        XCTAssertTrue(lines.contains("Upscaling ×4 with FakeVSR — frame 1 of 6"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("Upscaling ×4 with FakeVSR — frame 6 of 6"), lines.joined(separator: "\n"))
    }

    /// A still cannot take the whole-clip tier: refused with one wording, before the enhancer runs.
    func testStillAskedForLiveActionIsRefusedBeforeTheEnhancer() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(width: 64, height: 48, to: src)
        let enhancer = TieredEnhancer()
        var result: OptimizeResult?
        for await r in try ForgeOptimizer(enhancer: enhancer, videoUpscaler: FakeVideoUpscaler())
            .optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                      Options(quality: .balanced, enhance: .on, upscale: .x4, upscaleTier: .liveAction)) {
            result = r
        }
        let r = try XCTUnwrap(result)
        guard case .failed(let why) = r.status else { return XCTFail("expected a failed item, got \(r.status)") }
        XCTAssertEqual(why, "upscale tier 'live-action' unavailable: " + UpscaleTier.liveActionStillReason)
        XCTAssertEqual(enhancer.calls.count, 0)

        // An enhancer that predates the tier refuses it too, by the default.
        let verdict = await FixedScaleEnhancer(factor: 2).availability(of: .liveAction)
        XCTAssertFalse(verdict.isAvailable)
    }

    // MARK: - Helpers

    private func run(_ forge: ForgeOptimizer, _ src: URL, into out: URL, web: Bool) async throws -> OptimizeResult {
        let stream = web ? try forge.webOptimize(.url(src), to: .directory(out), ask)
                         : try forge.optimize(.url(src), to: .directory(out), ask)
        var result: OptimizeResult?
        for await r in stream { result = r }
        return try XCTUnwrap(result)
    }

    private func parsedReceipt(_ r: OptimizeResult) throws -> [String: Any] {
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(r)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func videoSize(_ url: URL) async throws -> (w: Int, h: Int) {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        return (Int(size.width), Int(size.height))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(width w: Int, height h: Int, to url: URL) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dst, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
    }
}

/// A whole-clip upscaler with FlashVSR's shape — video in, video only out, every frame kept at its own timestamp,
/// progress per emitted frame — that scales with CoreGraphics and writes HEVC. `refusal` is what `availability`
/// answers; `asked` records every (w, h, factor) it was asked about.
final class FakeVideoUpscaler: VideoUpscaler, @unchecked Sendable {
    let refusal: String?
    let calls = CallCounter()
    let asked = Recorded<(w: Int, h: Int, factor: Int)>()

    init(refusal: String? = nil) { self.refusal = refusal }

    static func factor(_ f: UpscaleFactor) -> Int { switch f { case .none: 1; case .x2: 2; case .x4: 4; case .x6: 6; case .x8: 8 } }

    func availability(of tier: UpscaleTier, width: Int, height: Int,
                      factor: UpscaleFactor) async -> UpscaleTierAvailability {
        asked.add((width, height, Self.factor(factor)))
        if let refusal { return .unavailable(tier, model: "FakeVSR", reason: refusal) }
        return .available(tier, model: "FakeVSR")
    }

    func upscale(_ input: URL, factor: UpscaleFactor, tier: UpscaleTier, output: URL,
                 progress: @escaping @Sendable (Int, Int) -> Void) async throws -> VideoUpscaleReport {
        calls.increment()
        let f = Self.factor(factor)
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ForgeError.decodeFailed(input)
        }
        let size = try await track.load(.naturalSize)
        let w = Int(size.width) * f, h = Int(size.height) * f
        let frames = try Self.readFrames(asset, track)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for (n, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
            adaptor.append(try Self.scaled(frame.image, to: w, h), withPresentationTime: frame.time)
            progress(n + 1, frames.count)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ForgeError.renderFailed("fake upscaler writer") }
        return VideoUpscaleReport(tier: tier, model: "FakeVSR")
    }

    private static func readFrames(_ asset: AVAsset, _ track: AVAssetTrack) throws -> [(image: CGImage, time: CMTime)] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        var frames: [(CGImage, CMTime)] = []
        while let sample = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb),
                                      height: CVPixelBufferGetHeight(pb), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
                  let image = ctx.makeImage() else { continue }
            frames.append((image, CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        return frames
    }

    private static func scaled(_ image: CGImage, to w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let buf = pb else { throw ForgeError.renderFailed("pixel buffer") }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
}

final class Recorded<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
