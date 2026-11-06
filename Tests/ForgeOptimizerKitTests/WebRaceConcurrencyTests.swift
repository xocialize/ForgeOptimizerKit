import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MediaBridge
import MediaImport
import MediaMeasure
@testable import ForgeOptimizerKit

/// The web race runs its lossless leg (PNG + lossless WebP) at the same time as its lossy leg (the
/// floor search plus the JPEG hand-over) — AB-T-0145. Two things are pinned here:
///
/// 1. **They overlap.** A stand-in encoder whose lossless encode waits for the lossy search to start:
///    under the sequential race of 0.27.0 the lossless encode would wait out its timeout, because the
///    lossy search only started after it returned.
/// 2. **The bytes are the legs' own.** Whatever runs beside it, the deliverable is byte-for-byte the
///    encode the winning leg makes on its own — concurrency changes when a leg runs, never what it
///    writes. The corpus-level proof (ten stills, a flat graphic and a transparent case, byte-identical
///    to 0.27.0 at three presets) is `Tools/webprace --ab`.
final class WebRaceConcurrencyTests: XCTestCase {

    /// Lossy = JPEG at the knob's quality (deterministic, and smaller than PNG on the noisy fixture);
    /// lossless = PNG without its `eXIf` chunk (exact, a few bytes under ImageIO's PNG). With
    /// `rendezvous`, the lossless encode waits up to 5 s for the lossy search's first encode.
    private final class Rendezvous: ExternalStillEncoder, @unchecked Sendable {
        let lossyStarted = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var signalled = false
        private var _overlapped: Bool?
        let rendezvous: Bool
        init(rendezvous: Bool) { self.rendezvous = rendezvous }

        var overlapped: Bool? { lock.lock(); defer { lock.unlock() }; return _overlapped }
        var format: ExternalStillFormat { .webp }
        var supportsAlpha: Bool { true }
        var supportsLossless: Bool { true }

        func encode(_ image: CGImage, quality: Double) throws -> Data {
            lock.lock()
            if !signalled { signalled = true; lossyStarted.signal() }
            lock.unlock()
            return Self.jpeg(image, quality: quality)
        }
        func encodeLossless(_ image: CGImage) throws -> Data {
            if rendezvous {
                let met = lossyStarted.wait(timeout: .now() + 5) == .success
                lock.lock(); _overlapped = met; lock.unlock()
            }
            return Self.strippingEXIF(Self.png(image))
        }

        static func jpeg(_ image: CGImage, quality: Double) -> Data {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
        static func png(_ image: CGImage) -> Data {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
        static func strippingEXIF(_ png: Data) -> Data {
            var out = Data(png.prefix(8))
            var i = 8
            while i + 12 <= png.count {
                let length = png[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
                let type = String(bytes: png[i + 4..<i + 8], encoding: .ascii)
                if type != "eXIf" { out.append(png[i..<i + 12 + length]) }
                i += 12 + length
            }
            return out
        }
    }

    private var tmp: URL!

    override func setUpWithError() throws {
        MediaBridge.unregisterAllExternalStillEncoders()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("web-race-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MediaBridge.unregisterAllExternalStillEncoders()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Photo-like: a gradient under deterministic noise — lossy beats PNG here by a wide margin.
    private func noisy(_ n: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        var seed: UInt32 = 0x2545F491
        for y in 0..<n { for x in 0..<n {
            let i = (y * n + x) * 4
            for c in 0..<3 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Int(seed >> 28) - 8
                bytes[i + c] = UInt8(clamping: (x * 255 / n + y * (c + 1) * 40 / n) % 256 + noise)
            }
        } }
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Flat: four solid blocks — the exact candidate beats any lossy encode here.
    private func flat(_ n: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let h = CGFloat(n) / 2
        for (i, rgb) in [(0.9, 0.1, 0.1), (0.1, 0.6, 0.2), (0.1, 0.2, 0.8), (1.0, 0.9, 0.2)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i % 2) * h, y: CGFloat(i / 2) * h, width: h, height: h))
        }
        return ctx.makeImage()!
    }

    private func write(_ image: CGImage, _ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        return url
    }

    private func run(_ src: URL, _ options: Options) async throws -> (OptimizeResult, Data) {
        let out = tmp.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var results: [OptimizeResult] = []
        for try await r in try ForgeOptimizer().webOptimize(.url(src), to: .directory(out), options) { results.append(r) }
        let r = try XCTUnwrap(results.first)
        guard case .file(let file) = r.output else { XCTFail("expected a file (got \(r.status))"); return (r, Data()) }
        return (r, try Data(contentsOf: file))
    }

    private var smallest: Options { var o = Options(); o.webLossless = .smallest; return o }

    // MARK: - Overlap

    /// The lossless encode returns only once the lossy search has started — so the two legs are in
    /// flight together. Before 0.27.1 this waited out the 5 s timeout.
    func testLosslessLegOverlapsTheLossySearch() async throws {
        let encoder = Rendezvous(rendezvous: true)
        MediaBridge.register(externalStillEncoder: encoder)
        let (r, _) = try await run(try write(noisy(160), "noisy.png"), smallest)
        XCTAssertEqual(encoder.overlapped, true, "the lossy search must start while the lossless leg is still encoding")
        XCTAssertEqual(r.recipe.codec, "WebP", "the lossy leg wins on photo-like pixels")
    }

    // MARK: - Same bytes

    /// Lossy wins: the deliverable is exactly the lossy leg's own search result, run alone.
    func testLossyWinnerIsTheLossyLegsOwnBytes() async throws {
        MediaBridge.register(externalStillEncoder: Rendezvous(rendezvous: false))
        let src = try write(noisy(160), "noisy.png")
        let (r, shipped) = try await run(src, smallest)
        XCTAssertEqual(r.recipe.codec, "WebP")
        let cg = try XCTUnwrap(ForgeOptimizer.loadOrientedStill(src)).image
        let scalars = SSIMULACRA2Metal.shared?.channelScalarsFunction
        let (alone, format) = try await ForgeOptimizer.webLossyLeg(cg, lane: .webp, floor: Options().quality.floor,
                                                                   pin: nil, transparent: false, scalars: scalars)
        XCTAssertEqual(format, .webp)
        XCTAssertEqual(shipped, try XCTUnwrap(alone).data, "the search under concurrency writes the bytes it writes alone")
    }

    /// The exact candidate wins: the deliverable is the lossless encoder's bytes for the decoded pixels.
    func testLosslessWinnerIsTheLosslessEncodersOwnBytes() async throws {
        MediaBridge.register(externalStillEncoder: Rendezvous(rendezvous: false))
        let src = try write(flat(160), "flat.png")
        let (r, shipped) = try await run(src, smallest)
        XCTAssertEqual(r.recipe.codec, "WebP-lossless")
        let cg = try XCTUnwrap(ForgeOptimizer.loadOrientedStill(src)).image
        XCTAssertEqual(shipped, Rendezvous.strippingEXIF(Rendezvous.png(cg)))
    }

    /// Repeated runs ship identical bytes, lossy and lossless winners alike — the legs share the
    /// scoring queue and the GPU scorer, and neither perturbs the other's measured score.
    func testRepeatedRunsAreByteIdentical() async throws {
        MediaBridge.register(externalStillEncoder: Rendezvous(rendezvous: false))
        for (name, image) in [("noisy.png", noisy(160)), ("flat.png", flat(160))] {
            let src = try write(image, name)
            let (_, first) = try await run(src, smallest)
            for _ in 0..<3 {
                let (_, again) = try await run(src, smallest)
                XCTAssertEqual(again, first, name)
            }
        }
    }

    /// The JPEG hand-over rides inside the lossy leg: an unpinned WebP search that misses the floor
    /// still hands over to JPEG, and the JPEG shipped is the one the hand-over makes alone.
    func testJPEGHandOverIsUnchanged() async throws {
        final class Missing: ExternalStillEncoder {
            var format: ExternalStillFormat { .webp }
            var supportsAlpha: Bool { true }
            var supportsLossless: Bool { true }
            func encode(_ image: CGImage, quality: Double) throws -> Data { Rendezvous.jpeg(image, quality: 0.02) }
            func encodeLossless(_ image: CGImage) throws -> Data { Rendezvous.strippingEXIF(Rendezvous.png(image)) }
        }
        MediaBridge.register(externalStillEncoder: Missing())
        let src = try write(noisy(160), "noisy.png")
        var options = smallest
        options.stripMetadata = true          // compare the encode itself, not a metadata re-wrap
        let (r, shipped) = try await run(src, options)
        XCTAssertEqual(r.recipe.codec, "JPEG", "a missed WebP search hands over to JPEG before the exact leg")
        let cg = try XCTUnwrap(ForgeOptimizer.loadOrientedStill(src)).image
        let jpeg = try await ImageQualityTarget.encodeJPEG(cg, targetScore: Options().quality.floor,
                                                           channelScalars: SSIMULACRA2Metal.shared?.channelScalarsFunction)
        XCTAssertEqual(shipped, jpeg.data)
    }
}
