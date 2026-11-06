import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MediaBridge
import MediaImport
@testable import ForgeOptimizerKit

/// The lossless WebP candidate in the web race's lossless leg (AB-T-0142). Proven, like the lossy lane,
/// with pure-Swift stand-ins registered through media-bridge's still-encoder seam — the Kit must not
/// link libwebp. The stand-ins control the only two things the race reads from a lossless candidate:
/// its byte count and its measured round-trip. `ExactSmaller` is exact and a few bytes under PNG (it
/// is ImageIO's PNG minus the `eXIf` chunk); `LossySmaller` is smaller but not exact (JPEG bytes).
/// The real encoder's lossless exactness, alpha included, is pinned in webp-swift and measured on the
/// corpus by `Tools/webprace --lossless`.
final class WebPLosslessLaneTests: XCTestCase {

    /// Lossy lane = ImageIO PNG (exact, so it always clears the floor, and never smaller than PNG):
    /// the race's winner is then decided by the lossless leg alone.
    private struct ExactSmaller: ExternalStillEncoder {
        let calls = Counter()
        var format: ExternalStillFormat { .webp }
        var supportsAlpha: Bool { true }
        var supportsLossless: Bool { true }
        func encode(_ image: CGImage, quality: Double) throws -> Data { try png(image) }
        func encodeLossless(_ image: CGImage) throws -> Data {
            calls.bump()
            return Self.strippingEXIF(try png(image))
        }
        func png(_ image: CGImage) throws -> Data {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
        /// Drops the `eXIf` chunk ImageIO writes into every PNG: same pixels, same colour chunks, fewer bytes.
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

    /// Smaller than PNG, but its round-trip is not exact: must never take the lossless leg.
    private struct LossySmaller: ExternalStillEncoder {
        var format: ExternalStillFormat { .webp }
        var supportsAlpha: Bool { true }
        var supportsLossless: Bool { true }
        func encode(_ image: CGImage, quality: Double) throws -> Data { try ExactSmaller().png(image) }
        func encodeLossless(_ image: CGImage) throws -> Data {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
    }

    /// A lossy lane that cannot clear any floor, and an exact lossless one.
    private struct MissingLossy: ExternalStillEncoder {
        var format: ExternalStillFormat { .webp }
        var supportsAlpha: Bool { true }
        var supportsLossless: Bool { true }
        func encode(_ image: CGImage, quality: Double) throws -> Data {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.02] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
        func encodeLossless(_ image: CGImage) throws -> Data { ExactSmaller.strippingEXIF(try ExactSmaller().png(image)) }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private var tmp: URL!

    override func setUpWithError() throws {
        MediaBridge.unregisterAllExternalStillEncoders()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("webp-lossless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MediaBridge.unregisterAllExternalStillEncoders()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A flat graphic — hard-edged blocks and stripes, the content lossless WebP exists for.
    private func makeGraphic(_ n: Int, alpha: Bool = false, space: CFString = CGColorSpace.sRGB) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let i = (y * n + x) * 4
            let block = (x / 16 + y / 16) % 3
            bytes[i]     = block == 0 ? 230 : block == 1 ? 20 : 120
            bytes[i + 1] = block == 0 ? 40 : (x % 8 < 4 ? 200 : 60)
            bytes[i + 2] = block == 2 ? 250 : 90
            // Straight alpha 0 / 128 / 255 regions, premultiplied below as CoreGraphics requires.
            let a: UInt8 = !alpha ? 255 : (x < n / 4 ? 0 : x < n / 2 ? 128 : 255)
            bytes[i + 3] = a
            if alpha { for c in 0..<3 { bytes[i + c] = UInt8(Int(bytes[i + c]) * Int(a) / 255) } }
        } }
        let cs = CGColorSpace(name: space)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs, bitmapInfo: info.rawValue)!
        return ctx.makeImage()!
    }

    private func source(_ name: String = "graphic.png", alpha: Bool = false,
                        space: CFString = CGColorSpace.sRGB) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, makeGraphic(128, alpha: alpha, space: space), nil)
        CGImageDestinationFinalize(dst)
        return url
    }

    private func run(_ src: URL, _ options: Options) async throws -> OptimizeResult {
        let forge = ForgeOptimizer()
        var results: [OptimizeResult] = []
        // A subdirectory per run: the deliverable must never land beside, or over, the source.
        let out = tmp.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for try await r in try forge.webOptimize(.url(src), to: .directory(out), options) { results.append(r) }
        return try XCTUnwrap(results.first)
    }

    private func smallest(_ base: Options = Options()) -> Options {
        var o = base; o.webLossless = .smallest; return o
    }

    // MARK: - The lane

    /// The headline: an exact WebP smaller than PNG takes the lossless leg, and the receipt says
    /// `WebP-lossless` — never the lossy lane's bare `WebP` — with no floor (it is exact).
    func testSmallerExactWebPShipsAsWebPLossless() async throws {
        let encoder = ExactSmaller()
        MediaBridge.register(externalStillEncoder: encoder)
        let r = try await run(try source(), smallest())
        guard case .optimized = r.status else { return XCTFail("must optimize (got \(r.status))") }
        XCTAssertEqual(r.recipe.codec, "WebP-lossless")
        XCTAssertEqual(r.recipe.codec, ForgeOptimizer.webPLosslessCodecName)
        XCTAssertNil(r.recipe.qualityFloor, "an exact deliverable carries no floor")
        XCTAssertEqual(r.outputType, .webP)
        XCTAssertEqual(r.after.qualityScore ?? 0, 100, accuracy: 0.01, "the round-trip is measured, and exact")
        XCTAssertTrue(r.recipe.strippedMetadata, "WebP ships metadata-clean and the receipt says so")
        XCTAssertTrue(String(describing: r.recipe).contains("WebP-lossless"), "\(r.recipe)")
        if case .file(let out) = r.output { XCTAssertEqual(out.pathExtension, "webp") } else { XCTFail("expected a file") }
        XCTAssertEqual(encoder.calls.value, 1, "exact candidates are encoded once — no search")
    }

    /// `.png` is the race every earlier release ran: the lossless encoder is never even called.
    func testPNGLeavesTheLosslessLegToPNG() async throws {
        let encoder = ExactSmaller()
        MediaBridge.register(externalStillEncoder: encoder)
        var options = Options(); options.webLossless = .png
        let r = try await run(try source(), options)
        // The source is ImageIO's own PNG, so the honest-skip gate may keep it; the recipe still names
        // the codec the race chose.
        XCTAssertEqual(r.recipe.codec, "PNG")
        XCTAssertNotEqual(r.outputType, .webP)
        XCTAssertEqual(encoder.calls.value, 0)
    }

    /// The default is the gate's verdict; whatever it is, a default `Options` carries it.
    func testDefaultOptionsCarryTheGatedDefault() {
        XCTAssertEqual(Options().webLossless, Options.defaultWebLossless)
    }

    /// A tie keeps PNG — the bytes earlier releases shipped.
    func testATieKeepsPNG() {
        func wins(_ bytes: Int, _ score: Double, pinned: Bool = false) -> Bool {
            ForgeOptimizer.losslessWebPWins(webpBytes: bytes, webpScore: score, pngBytes: 100, pngScore: 100,
                                            pinnedWebP: pinned)
        }
        XCTAssertFalse(wins(100, 100))
        XCTAssertTrue(wins(99, 100))
        XCTAssertTrue(wins(100, 100, pinned: true),
                      "under a .webp pin PNG cannot ship, so size against it does not matter")
        XCTAssertFalse(wins(50, 99.5), "smaller but not exact loses")
        XCTAssertFalse(wins(50, 99.5, pinned: true), "a pin does not excuse inexactness")
    }

    /// Exactness is measured, never assumed from "lossless": a smaller candidate whose round-trip
    /// scores below PNG's loses the leg.
    func testASmallerCandidateThatIsNotExactLoses() async throws {
        MediaBridge.register(externalStillEncoder: LossySmaller())
        let r = try await run(try source(), smallest())
        XCTAssertNotEqual(r.recipe.codec, "WebP-lossless")
        XCTAssertEqual(r.recipe.codec, "PNG", "the lossy stand-in is PNG-sized, so PNG ships")
    }

    /// A caller who chose JPEG chose a destination where WebP does not play: the lossless leg stays PNG.
    func testJPEGLaneNeverRacesLosslessWebP() async throws {
        let encoder = ExactSmaller()
        MediaBridge.register(externalStillEncoder: encoder)
        let r = try await run(try source(), smallest(Options(webLossy: .jpeg)))
        XCTAssertNotEqual(r.outputType, .webP)
        XCTAssertEqual(encoder.calls.value, 0)
    }

    func testPNGPinNeverRacesLosslessWebP() async throws {
        let encoder = ExactSmaller()
        MediaBridge.register(externalStillEncoder: encoder)
        let r = try await run(try source(), smallest(Options(output: .png)))
        XCTAssertEqual(r.recipe.codec, "PNG")
        XCTAssertEqual(encoder.calls.value, 0)
    }

    /// A wider-gamut source cannot survive an 8-bit sRGB bitstream exactly: PNG keeps it.
    func testDisplayP3SourceKeepsPNG() async throws {
        let encoder = ExactSmaller()
        MediaBridge.register(externalStillEncoder: encoder)
        let r = try await run(try source("p3.png", space: CGColorSpace.displayP3), smallest())
        XCTAssertEqual(r.recipe.codec, "PNG")
        XCTAssertEqual(encoder.calls.value, 0, "an inexact source is never handed to the lossless encoder")
    }

    func testExactnessPredicate() {
        XCTAssertTrue(ForgeOptimizer.webPLosslessCanBeExact(makeGraphic(8)))
        XCTAssertTrue(ForgeOptimizer.webPLosslessCanBeExact(makeGraphic(8, alpha: true)))
        XCTAssertFalse(ForgeOptimizer.webPLosslessCanBeExact(makeGraphic(8, space: CGColorSpace.displayP3)))
        let deep = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 16, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        XCTAssertFalse(ForgeOptimizer.webPLosslessCanBeExact(deep), "16-bit does not fit an 8-bit bitstream")
    }

    /// Transparency survives the lossless leg: it races (WebP carries alpha) and the decoded alpha
    /// plane is bit-exact against the source.
    func testTransparencySurvivesWebPLossless() async throws {
        MediaBridge.register(externalStillEncoder: ExactSmaller())
        let src = try source("alpha.png", alpha: true)
        let r = try await run(src, smallest())
        XCTAssertEqual(r.recipe.codec, "WebP-lossless")
        guard case .file(let out) = r.output else { return XCTFail("expected a file") }
        let a = try XCTUnwrap(Self.decode(src)), b = try XCTUnwrap(Self.decode(out))
        XCTAssertEqual(Self.alphaPlane(a), Self.alphaPlane(b), "the alpha plane round-trips exactly")
        XCTAssertTrue(Self.alphaPlane(b).contains(0), "the fixture's transparent region is still transparent")
    }

    /// Under a `.webp` pin either WebP mode honours the pin: a lossy search that missed the floor
    /// yields to the exact lossless WebP instead of shipping below the floor.
    func testWebPPinShipsLosslessWhenTheLossySearchMisses() async throws {
        MediaBridge.register(externalStillEncoder: MissingLossy())
        let r = try await run(try source(), smallest(Options(output: .webp)))
        XCTAssertEqual(r.outputType, .webP)
        XCTAssertEqual(r.recipe.codec, "WebP-lossless")
        XCTAssertNil(r.recipe.qualityFloor)
        // …and with `.png` the pin keeps its earlier behaviour: the lossy WebP ships, best effort.
        var keep = Options(output: .webp); keep.webLossless = .png
        let k = try await run(try source("graphic-2.png"), keep)
        XCTAssertEqual(k.recipe.codec, "WebP")
    }

    // MARK: - Helpers

    static func decode(_ url: URL) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    static func alphaPlane(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<h).flatMap { y in (0..<w).map { base[y * ctx.bytesPerRow + $0] } }
    }
}
