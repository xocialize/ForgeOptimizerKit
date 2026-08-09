import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo
@testable import ForgeOptimizerKit

/// `webOptimize` — the web-universal deliverable verb: stills → PNG (lossless), video → H.264 + AAC
/// mp4. The semantics under test: a *conversion* delivers even when larger than the source (the user
/// asked for a web file, not a smaller file); the honest skip survives only where the input is
/// already web-native and the re-encode isn't smaller.
final class WebOptimizeTests: XCTestCase {

    private let forge = ForgeOptimizer()

    /// JPEG in → PNG out. The PNG is (much) larger — that must NOT skip: web-normalizing a lossy
    /// source is the verb's whole point. The measured round-trip score rides the receipt.
    /// SUPERSEDED CONTRACT, rewritten for the web-still RACE (2026-08-09): this test used to pin
    /// "a textured JPEG converts to PNG and delivers even when larger." The race exists precisely
    /// so photos stop inflating into PNG — a textured lossy source now re-races into a
    /// floor-searched JPEG. The deliver-even-when-larger semantic survives where it still applies:
    /// alpha content (JPEG can't carry it) — pinned in `testAlphaStillStaysPNG` and the honest-skip
    /// gate tests. JPEG sources remain size-gated web-native stills (`testJPEGSourceIsSizeGated`).
    func testTexturedJPEGRacesIntoFloorSearchedJPEG() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("input.jpg")
        try writeJPEG(makeTexturedImage(128, 128), to: src, quality: 0.5)

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o"))) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        switch r.status {
        case .optimized:
            XCTAssertEqual(r.outputType, .jpeg, "textured lossy content wins the race as JPEG")
            XCTAssertEqual(r.recipe.codec, "JPEG")
            XCTAssertNotNil(r.recipe.qualityFloor, "the lossy winner carries its floor")
            guard case .file(let out) = r.output else { return XCTFail("expected .file output") }
            XCTAssertEqual(out.pathExtension, "jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        case .skipped(let why):
            // A JPEG source is a web-native still: when the race can't beat it, the honest skip
            // (original IS the deliverable) is the correct outcome — never a larger file.
            XCTAssertTrue(why.contains("web-ready"), "skip must cite web-native gating: \(why)")
        case .failed(let why):
            XCTFail("unexpected failure: \(why)")
        }
    }

    /// PNG in → the size gate applies (the original is already a web deliverable): either an honest
    /// "already web-ready" skip, or a genuinely smaller PNG. Never a larger delivered file.
    func testPNGSourceIsSizeGated() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("input.png")
        try writePNG(makeTexturedImage(128, 128), to: src)
        let srcBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int)

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o"))) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        switch r.status {
        case .optimized:
            XCTAssertLessThan(r.after.bytes, srcBytes, "a delivered PNG-from-PNG must be smaller")
        case .skipped(let why):
            XCTAssertTrue(why.contains("web-ready"), "the skip must say the source already qualifies: \(why)")
        case .failed(let why):
            XCTFail("unexpected failure: \(why)")
        }
    }

    /// HEVC clip in → H.264-in-mp4 out, receipt says so, aggregation rides along (BRIDGE-061).
    func testVideoDeliversH264MP4() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("clip.mov")
        try makeGradientClip(at: src, w: 320, h: 240, frames: 30, codec: .hevc)

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o")),
                                             Options(quality: .aggressive)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else { return XCTFail("expected .optimized, got \(r.status)") }
        XCTAssertEqual(r.recipe.codec, "H.264")
        XCTAssertEqual(r.outputType, .mpeg4Movie)
        XCTAssertNotNil(r.after.qualityAggregation, "video receipts carry their aggregation")
        guard case .file(let out) = r.output else { return XCTFail("expected .file output") }
        XCTAssertEqual(out.pathExtension, "mp4")

        let vtracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let vfmts = try await XCTUnwrap(vtracks.first).load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(vfmts.first)),
                       kCMVideoCodecType_H264)
    }

    /// A floor the content can't reach (noise, floor 90) must still produce the web deliverable —
    /// the conversion is a normalize; the receipt carries the honest shortfall.
    func testVideoFloorMissStillDeliversWebMP4() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("noise.mov")
        try makeGradientClip(at: src, w: 320, h: 240, frames: 30, codec: .hevc, noise: true)

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o")),
                                             Options(quality: .max)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else { return XCTFail("expected best-effort delivery, got \(r.status)") }
        let score = try XCTUnwrap(r.after.qualityScore)
        XCTAssertLessThan(score, 90, "precondition: the floor was genuinely missed")
        XCTAssertEqual(r.recipe.qualityFloor, 90, "the receipt states what was asked…")
        guard case .file(let out) = r.output else { return XCTFail("expected .file output") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    /// MKV in → automatic normalize (pure-Swift demux → HEVC mp4) → web encode. The production
    /// "whatever this is, make it playable" path. Fixture needs the dev-machine ffmpeg (fixture
    /// generation only — nothing links it); skips where absent.
    func testMKVAutoNormalizesToWebMP4() async throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("ffmpeg not installed (test-fixture generation only)")
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("clip.mkv")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: ffmpeg)
        gen.arguments = ["-hide_banner", "-loglevel", "error",
                         "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=1",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", src.path]
        try gen.run(); gen.waitUntilExit()
        guard gen.terminationStatus == 0 else { throw XCTSkip("ffmpeg could not build the MKV fixture") }

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o")),
                                             Options(quality: .aggressive)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else { return XCTFail("expected delivery, got \(r.status)") }
        // H.264-in-MKV may legitimately arrive either way: a lossless remux (when AVFoundation can
        // passthrough the container) or the normalize→encode chain. Both are honest deliverables;
        // the receipt just has to say which ran.
        XCTAssertTrue(r.recipe.normalized || r.recipe.remuxed, "\(r.recipe)")
        XCTAssertEqual(r.recipe.codec, "H.264")
        guard case .file(let out) = r.output else { return XCTFail("expected .file output") }
        XCTAssertEqual(out.pathExtension, "mp4")
        let vtracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let vfmts = try await XCTUnwrap(vtracks.first).load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(vfmts.first)),
                       kCMVideoCodecType_H264)
    }

    /// Web-safe streams in the wrong wrapper, content the search can't beat (noise, floor 90):
    /// the lossless remux ships — ~source size, `remuxed` on the recipe, and NO score/floor on the
    /// receipt because nothing lossy ran. This is the IMG_0007 case: the old path delivered a 2×
    /// best-effort re-encode; the right operation was a container change.
    func testWebSafeMOVDeliversLosslessRemuxWhenSearchCannotBeat() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("capture.mov")
        try makeGradientClip(at: src, w: 320, h: 240, frames: 30, codec: .h264, noise: true)
        let srcBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int)

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o")),
                                             Options(quality: .max)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else { return XCTFail("expected remux delivery, got \(r.status)") }
        XCTAssertTrue(r.recipe.remuxed, "the receipt must say this was a lossless rewrap: \(r.recipe)")
        XCTAssertNil(r.after.qualityScore, "no re-encode ran — a score would be a fabricated claim")
        XCTAssertNil(r.recipe.qualityFloor, "no floor gated a lossless passthrough")
        XCTAssertLessThan(abs(r.after.bytes - srcBytes), max(srcBytes / 10, 64 * 1024),
                          "a remux stays at ~source size (\(srcBytes) → \(r.after.bytes))")
        guard case .file(let out) = r.output else { return XCTFail("expected .file output") }
        XCTAssertEqual(out.pathExtension, "mp4")
        let vtracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let vfmts = try await XCTUnwrap(vtracks.first).load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(vfmts.first)),
                       kCMVideoCodecType_H264)
    }

    /// Same wrapper situation, compressible content and a modest floor: the re-encode search finds
    /// a smaller floor-clearing encode and BEATS the remux — that must ship instead, with the full
    /// quality receipt.
    func testWebSafeMOVReencodeWinsWhenSmallerAndFloorMet() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("capture.mov")
        try makeGradientClip(at: src, w: 320, h: 240, frames: 30, codec: .h264)
        let srcBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int)

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o")),
                                             Options(quality: .aggressive)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else { return XCTFail("expected delivery, got \(r.status)") }
        XCTAssertFalse(r.recipe.remuxed, "a winning re-encode is not a remux")
        XCTAssertEqual(r.recipe.qualityFloor, 70)
        let score = try XCTUnwrap(r.after.qualityScore)
        XCTAssertGreaterThanOrEqual(score, 70, "the floor is the constraint the winner cleared")
        XCTAssertLessThan(r.after.bytes, srcBytes / 2,
                          "the re-encode only ships when meaningfully smaller than the remux")
    }

    /// An H.264-in-mp4 source is already web-ready → native semantics: shrink, or skip honestly.
    /// Never a larger delivered file.
    func testWebReadyVideoSourceIsSizeGated() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("clip.mp4")
        try makeGradientClip(at: src, w: 320, h: 240, frames: 30, codec: .h264)
        let ready = await ForgeOptimizer.isWebReadyVideo(src)
        XCTAssertTrue(ready, "H.264-in-mp4, no audio → web-ready")

        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o")),
                                             Options(quality: .aggressive)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        switch r.status {
        case .optimized:
            XCTAssertLessThan(r.after.bytes, r.before.bytes,
                              "web-ready source only re-delivers when genuinely smaller")
        case .skipped(let why):
            XCTAssertTrue(why.contains("web-ready") || why.contains("floor"),
                          "the skip must name the reason: \(why)")
        case .failed(let why):
            XCTFail("unexpected failure: \(why)")
        }
    }

    /// Request-pipeline form: exact host URL + context echo + authoritative `.png` output type.
    func testRequestPipelineWebOptimize() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("input.jpg")
        try writeJPEG(makeTexturedImage(96, 96), to: src, quality: 0.6)
        let outURL = tmp.appendingPathComponent("variants/entity-7--web.png")

        var results: [OptimizeResult] = []
        for await r in forge.webOptimize([OptimizeRequest(input: src, output: outURL, context: "entity-7")]) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        XCTAssertEqual(r.context, "entity-7")
        XCTAssertEqual(r.outputType, .png)
        guard case .file(let written) = r.output else { return XCTFail("expected .file output") }
        XCTAssertEqual(written, outURL, "must write to the host-dictated exact URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Gradient + deterministic texture: enough detail that JPEG→PNG genuinely grows (a flat
    /// gradient PNG can undercut a JPEG and silently invalidate the larger-yet-delivered assertion).
    private func makeTexturedImage(_ w: Int, _ h: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let noise = ((x * 131 + y * 57) % 64) - 32
            let i = (y * w + x) * 4
            bytes[i] = UInt8(clamping: x * 2 + noise)
            bytes[i + 1] = UInt8(clamping: y * 2 + noise)
            bytes[i + 2] = UInt8(clamping: 128 + noise)
            bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
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

    private func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ForgeError.renderFailed("jpeg destination")
        }
        CGImageDestinationAddImage(dst, image, [
            kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw ForgeError.renderFailed("jpeg finalize") }
    }

    /// Smooth drifting gradient (compressible — the floor must be reachable) at a pinned real
    /// bitrate; no audio. Same fixture reasoning as media-bridge's WebDeliverableTests.
    /// `noise: true` flips to incompressible LCG frames — the floor-unreachable fixture.
    private func makeGradientClip(at url: URL, w: Int, h: Int, frames: Int,
                                  codec: AVVideoCodecType, noise: Bool = false) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url,
                                       fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                if noise {
                    var seed = UInt32(truncatingIfNeeded: i &* 2654435761 | 1)
                    for j in 0..<(rowBytes * h) {
                        seed = seed &* 1664525 &+ 1013904223
                        p[j] = UInt8(truncatingIfNeeded: seed >> 16)
                    }
                } else {
                    for y in 0..<h { for x in 0..<w {
                        let o = y * rowBytes + x * 4
                        p[o] = UInt8((x * 255 / w + i * 6) % 256)
                        p[o + 1] = UInt8(y * 255 / h)
                        p[o + 2] = UInt8((x + y) * 255 / (w + h))
                        p[o + 3] = 255
                    } }
                }
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
