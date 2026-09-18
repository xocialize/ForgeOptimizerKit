import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MediaBridge
import MediaImport
@testable import ForgeOptimizerKit

/// The WebP lane of the web still race, proven with a pure-Swift stand-in registered through
/// media-bridge's still-encoder seam — exactly as the decode-side seam was proven with a fake VP9
/// decoder. The fake claims WebP and emits ImageIO bytes (JPEG for opaque images, PNG when there is
/// alpha), which is enough to pin the Kit's PLUMBING: which lane runs, what the receipt says, what
/// the pin and the preference do, and that nothing registered means nothing changed. The real
/// encoder's behaviour is pinned in webp-swift, where libwebp lives.
final class WebPLaneTests: XCTestCase {

    private struct FakeWebP: ExternalStillEncoder {
        var format: ExternalStillFormat { .webp }
        var supportsAlpha: Bool { true }
        var supportsLossless: Bool { true }
        func encode(_ image: CGImage, quality: Double) throws -> Data {
            let alpha: Bool = ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
            return try Self.imageIO(image, type: alpha ? .png : .jpeg, quality: quality)
        }
        func encodeLossless(_ image: CGImage) throws -> Data { try Self.imageIO(image, type: .png, quality: 1) }
        static func imageIO(_ image: CGImage, type: UTType, quality: Double) throws -> Data {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
    }

    /// A 24×24 lossy WebP (292 bytes) written by libwebp 1.6.0 at q=60 — the only way to get WebP
    /// bytes into a test that must not link libwebp. ImageIO decodes it; the probe must call it WebP.
    private static let tinyWebP = Data(base64Encoded:
        "UklGRhwBAABXRUJQVlA4IBABAABwBgCdASoYABgAPq1Em0mmI6IhMAwAwBWJbACdMoR1B7pxpNEvrhsG6jNtJc9jNy9bRXizugDDXMRan0AA/up7eACJR8FwWx3M+lxqA66ttwutk5QFsY2LwYkhf4pzHkCMA3PA1gDnyAHv0jvxTL4mjn5aMj65viIjrOCWU+Qz7Ae+PYfJk0d2nZgFrAXVtP0yghzc0EK5DhzSeZXYwt/ciFgekqKd012v89ogjGxcnhdxAcDA8UPa4KqWWGWUcKO7U4el5+apgAa/3eKGcTHr8NgkRdZVfnFK6lLe3fLDkouDy/EvTUQNDGv5ELrgBIShUlPmtjVI9Ru+NEd51b6jBEF+yjX+pvxD0GOPlYAAAA==")!

    private var tmp: URL!

    override func setUpWithError() throws {
        MediaBridge.unregisterAllExternalStillEncoders()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("webp-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MediaBridge.unregisterAllExternalStillEncoders()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Fixtures (the race tests' photo-like still)

    private func makePhotoImage(_ n: Int, alpha: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 0x9E3779B9
        func grain() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(Int32(truncatingIfNeeded: seed >> 8) % 13) - 6
        }
        for y in 0..<n { for x in 0..<n {
            let fx = Double(x) / Double(n), fy = Double(y) / Double(n)
            let l1 = 110 + 70 * sin(fx * 4.1 + 0.6) * cos(fy * 2.9 + 1.1)
            let l2 = 40 * sin((fx + fy) * 6.3)
            let i = (y * n + x) * 4
            bytes[i]     = UInt8(clamping: Int(l1 + l2 * 0.7 + grain()))
            bytes[i + 1] = UInt8(clamping: Int(l1 * 0.9 + l2 + grain()))
            bytes[i + 2] = UInt8(clamping: Int(l1 * 1.1 + l2 * 0.4 + grain()))
            bytes[i + 3] = alpha && x < n / 2 ? 128 : 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs, bitmapInfo: info.rawValue)!
        return ctx.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, image, nil)
        CGImageDestinationFinalize(dst)
    }

    private func photoSource(_ name: String = "photo.png", alpha: Bool = false) throws -> URL {
        let src = tmp.appendingPathComponent(name)
        try writePNG(makePhotoImage(256, alpha: alpha), to: src)
        return src
    }

    private func run(_ src: URL, _ options: Options = Options(),
                     to destination: Destination? = nil) async throws -> OptimizeResult {
        let forge = ForgeOptimizer()
        var results: [OptimizeResult] = []
        for try await r in try forge.webOptimize(.url(src), to: destination ?? .directory(tmp), options) {
            results.append(r)
        }
        return try XCTUnwrap(results.first)
    }

    // MARK: - The lane

    func testRegisteredEncoderIsTheDefaultLossyLane() async throws {
        MediaBridge.register(externalStillEncoder: FakeWebP())
        let r = try await run(try photoSource())
        guard case .optimized = r.status else { return XCTFail("must optimize (got \(r.status))") }
        XCTAssertEqual(r.outputType, .webP, "with an encoder registered, the lossy lane is WebP")
        XCTAssertEqual(r.recipe.codec, "WebP")
        XCTAssertEqual(r.recipe.qualityFloor, Options().quality.floor, "the lossy winner carries its floor")
        if case .file(let out) = r.output { XCTAssertEqual(out.pathExtension, "webp") } else { XCTFail("expected a file") }
    }

    /// Gate G3 in one test: nothing registered → the race is exactly what it was.
    func testNothingRegisteredKeepsJPEG() async throws {
        let r = try await run(try photoSource())
        XCTAssertEqual(r.outputType, .jpeg)
        XCTAssertEqual(r.recipe.codec, "JPEG")
    }

    func testJPEGPreferenceOutranksARegisteredEncoder() async throws {
        MediaBridge.register(externalStillEncoder: FakeWebP())
        let r = try await run(try photoSource(), Options(webLossy: .jpeg))
        XCTAssertEqual(r.outputType, .jpeg, "`.jpeg` keeps the JPEG lane for email/Office deliverables")
        XCTAssertEqual(r.recipe.codec, "JPEG")
    }

    func testWebPPreferenceFailsHonestlyWithoutAnEncoder() async throws {
        let r = try await run(try photoSource(), Options(webLossy: .webp))
        guard case .failed(let why) = r.status else { return XCTFail("must fail, not ship JPEG under another name (got \(r.status))") }
        XCTAssertTrue(why.contains("WebP encoder"), why)
    }

    func testExplicitWebPPinFailsHonestlyWithoutAnEncoder() async throws {
        let r = try await run(try photoSource(), Options(output: .webp))
        guard case .failed(let why) = r.status else { return XCTFail("got \(r.status)") }
        XCTAssertTrue(why.contains("WebP encoder"), why)
    }

    func testExplicitWebPPinDeliversWebP() async throws {
        MediaBridge.register(externalStillEncoder: FakeWebP())
        let r = try await run(try photoSource(), Options(output: .webp))
        XCTAssertEqual(r.outputType, .webP)
        XCTAssertEqual(r.recipe.codec, "WebP")
    }

    func testHostPinnedWebPExtensionPinsTheLane() async throws {
        MediaBridge.register(externalStillEncoder: FakeWebP())
        let pinned = tmp.appendingPathComponent("entity-7--web.webp")
        let r = try await run(try photoSource(), to: .fileURL(pinned))
        XCTAssertEqual(r.outputType, .webP)
        if case .file(let out) = r.output { XCTAssertEqual(out, pinned) } else { XCTFail("expected the pinned file") }
    }

    func testAJPEGPinStillRefusesTransparency() async throws {
        MediaBridge.register(externalStillEncoder: FakeWebP())
        let r = try await run(try photoSource("alpha.png", alpha: true), Options(output: .jpeg))
        guard case .failed(let why) = r.status else { return XCTFail("got \(r.status)") }
        XCTAssertTrue(why.contains("transparen"), why)
    }

    /// WebP carries alpha, so a transparent still is no longer benched to PNG — it races. The fake
    /// emits PNG bytes for alpha images, so which lane wins is a byte count; what must never happen
    /// is JPEG.
    func testTransparentStillRacesUnderWebPAndNeverBecomesJPEG() async throws {
        MediaBridge.register(externalStillEncoder: FakeWebP())
        let r = try await run(try photoSource("alpha.png", alpha: true))
        XCTAssertNotEqual(r.outputType, .jpeg, "transparency must never race into JPEG")
        if case .optimized = r.status {
            XCTAssertTrue(r.outputType == .webP || r.outputType == .png, "\(String(describing: r.outputType))")
        }
    }

    /// A WebP source is already web-native: the honest-skip gate must see it (a WebP re-encoded to
    /// WebP is a generation loss and a receipt claiming a saving it did not make).
    func testWebPSourceIsWebNativeForTheHonestSkipGate() async throws {
        MediaBridge.register(externalStillEncoder: FakeWebP())
        let src = tmp.appendingPathComponent("tiny.webp")
        try Self.tinyWebP.write(to: src)
        let r = try await run(src)
        switch r.status {
        case .skipped(let why):
            XCTAssertTrue(why.contains("WebP"), "the skip names the web-native format: \(why)")
        case .optimized:
            XCTAssertLessThan(r.after.bytes, Self.tinyWebP.count, "a delivery on a web-native source must be smaller")
        case .failed(let why):
            XCTFail("a WebP source must be accepted: \(why)")
        }
    }

    /// Claims WebP but caps its quality — a stand-in for WebP lossy's 4:2:0 ceiling at a high floor.
    private struct WeakWebP: ExternalStillEncoder {
        var format: ExternalStillFormat { .webp }
        var supportsAlpha: Bool { true }
        var supportsLossless: Bool { true }
        func encode(_ image: CGImage, quality: Double) throws -> Data {
            try FakeWebP.imageIO(image, type: .jpeg, quality: min(quality, 0.05))
        }
        func encodeLossless(_ image: CGImage) throws -> Data { try FakeWebP.imageIO(image, type: .png, quality: 1) }
    }

    /// The max-preset finding: when the WebP lane cannot clear the floor, the race tries JPEG before
    /// it settles for PNG — under `.webp` as well as `.auto`, because both only name a preference.
    func testWebPThatMissesTheFloorFallsBackToJPEG() async throws {
        MediaBridge.register(externalStillEncoder: WeakWebP())
        for lane in [WebLossyCodec.auto, .webp] {
            let r = try await run(try photoSource("photo-\(lane).png"), Options(webLossy: lane))
            guard case .optimized = r.status else { return XCTFail("got \(r.status)") }
            XCTAssertEqual(r.outputType, .jpeg, "under \(lane), a WebP lane that misses the floor hands over to JPEG")
            XCTAssertEqual(r.recipe.codec, "JPEG")
            XCTAssertEqual(r.recipe.qualityFloor, Options().quality.floor)
        }
    }

    /// A `.webp` PIN is a format demand, not a preference: it ships WebP best-effort, never JPEG.
    func testAWebPPinNeverFallsBackToJPEG() async throws {
        MediaBridge.register(externalStillEncoder: WeakWebP())
        let r = try await run(try photoSource(), Options(output: .webp))
        XCTAssertEqual(r.outputType, .webP)
    }

    func testAnalyzeRecommendsAnExplicitWebPPin() async throws {
        let forge = ForgeOptimizer()
        var analyses: [Analysis] = []
        for await a in forge.analyze(.url(try photoSource()), Options(output: .webp)) { analyses.append(a) }
        let a = try XCTUnwrap(analyses.first)
        XCTAssertEqual(a.recommendation.codec, "WebP")
        XCTAssertEqual(a.recommendation.qualityFloor, Options().quality.floor)
    }
}
