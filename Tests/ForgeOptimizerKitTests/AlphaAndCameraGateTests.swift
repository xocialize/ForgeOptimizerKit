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
///    (The animated-GIF → mp4 web conversion is the documented exception: it composites over
///    white and receipts the flatten — see `GIFConversionTests`.)
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

    /// An OPAQUE H.264 mp4 (smooth drifting gradient, no audio) — the consumer-gate arms need a
    /// clip the native path will actually search rather than refuse. Same fixture reasoning as
    /// `WebOptimizeTests.makeGradientClip`.
    private func makeOpaqueClip(w: Int = 320, h: Int = 240, frames: Int = 30) throws -> URL {
        let url = scratchURL("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
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
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buf)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h { for x in 0..<w {
                let o = y * stride + x * 4
                base[o] = UInt8((x * 255 / w + i * 6) % 256)
                base[o + 1] = UInt8(y * 255 / h)
                base[o + 2] = UInt8((x + y) * 255 / (w + h))
                base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        XCTAssertEqual(writer.status, .completed, "fixture writer: \(String(describing: writer.error))")
        return url
    }

    /// Collects `OptimizeProgress.detail` lines off the progress callback (thread-safe).
    private final class DetailLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    private func consumerRun(_ src: URL, _ options: Options) async throws -> (OptimizeResult, String) {
        let log = DetailLog()
        let r = try await one(try forge.optimize(.url(src), to: .directory(scratchDir()), options,
                                                  progress: { p in if let d = p.detail { log.add(d) } }))
        return (r, log.all)
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
    /// because the scorer cannot see alpha and would not notice if this broke. The `.heic` pin
    /// puts the run on conversion semantics (delivers regardless of size): the property under
    /// test is alpha carriage, not the byte race between a tiny PNG and HEIF's container overhead.
    func testTransparentStillKeepsAlphaThroughHEIC() async throws {
        let input = try makeTransparentPNG()
        let out = scratchDir()
        let r = try await one(try forge.optimize(.url(input), to: .directory(out), Options(output: .heic)))

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

    /// An explicit `.hevc` pin is a conversion REQUEST; one the Kit cannot honour fails the item
    /// (the `OutputFormat` contract) instead of reading as a policy skip that exits 0.
    func testExplicitHEVCPinOnAlphaVideoFailsRatherThanSkips() async throws {
        let input = try await makeAlphaMOV(.proRes4444)
        let r = try await one(try forge.optimize(.url(input), to: .directory(scratchDir()),
                                                  Options(output: .hevc)))
        guard case .failed(let why) = r.status else {
            return XCTFail("an unhonourable conversion request must fail, not \(r.status)")
        }
        XCTAssertTrue(why.contains("alpha"), why)
    }

    /// Destination validation outranks the refusal: a bad argument is the caller's error and must
    /// surface as `.failed`, never as a plausible-looking `.skipped`.
    func testInvalidDestinationOutranksTheAlphaSkip() async throws {
        let input = try await makeAlphaMOV(.hevcWithAlpha)
        let r = try await one(try forge.optimize(.url(input), to: .inMemory, Options()))
        guard case .failed(let why) = r.status else {
            return XCTFail("a bad destination is the caller's error, not a policy skip: \(r.status)")
        }
        XCTAssertTrue(why.contains("inMemory"), why)
    }

    /// The planning verb must agree with the executing verb: `analyze` never recommends a
    /// normalize that `optimize` will refuse.
    func testAnalyzeAgreesWithOptimizeOnAlphaVideo() async throws {
        let input = try await makeAlphaMOV(.hevcWithAlpha)
        var analyses: [Analysis] = []
        for await a in forge.analyze(.url(input), Options()) { analyses.append(a) }
        let a = try XCTUnwrap(analyses.first)
        XCTAssertEqual(String(describing: a.recommendation), "passthrough",
                       "analyze must not recommend a normalize optimize will refuse")
        XCTAssertTrue(a.estimate.note.contains("alpha"), a.estimate.note)
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

    /// The CALL SITE, not the predicate: reverting the `cameraGateAllowed` clause at the gate
    /// leaves `testCameraGatePolicy` green, so the suppression is pinned on a real `.consumer`
    /// optimize — the probe narration must not appear, the receipt must say WHY the gate did not
    /// run, and a stated `.graphic` must reach the search at the RAISED class floor (before the
    /// suppression a fired gate outranked it and took consumer's graphic floor from 90 to 70,
    /// scored against a softened reference — a stated class weakening its own promise).
    func testCameraGateSuppressionReachesTheSearch() async throws {
        let src = try makeOpaqueClip()

        let (off, offLog) = try await consumerRun(src, Options(quality: .consumer, cameraGate: .off))
        XCTAssertFalse(offLog.contains("Probing sensor noise"), offLog)
        XCTAssertEqual(off.recipe.cameraGate, "off")
        XCTAssertFalse(off.recipe.denoisedReference)

        let (graphic, graphicLog) = try await consumerRun(src, Options(quality: .consumer,
                                                                        contentClass: .graphic))
        XCTAssertFalse(graphicLog.contains("Probing sensor noise"), graphicLog)
        XCTAssertEqual(graphic.recipe.cameraGate, "suppressed")
        XCTAssertEqual(graphic.recipe.qualityFloor, 90,
                       "a stated .graphic reaches the search at the class floor, gate or no gate")
        XCTAssertFalse(graphic.recipe.denoisedReference)

        // Control: the default still probes. The narration precedes the macOS-26 availability
        // check inside the probe, so it appears on every OS; only the verdict is OS-dependent.
        let (auto, autoLog) = try await consumerRun(src, Options(quality: .consumer))
        XCTAssertTrue(autoLog.contains("Probing sensor noise"), autoLog)
        XCTAssertTrue(["clean", "fired", "unavailable"].contains(auto.recipe.cameraGate ?? ""),
                      "the receipt must carry the gate's disposition: \(auto.recipe)")
    }
}
