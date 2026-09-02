import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// The Kit's GIF routing: animated GIFs on the web profile convert to H.264 mp4 through the
/// standard floor search; single-frame GIFs stay in the still race like any other image.
final class GIFConversionTests: XCTestCase {

    /// `transparent: true` leaves the right half of every frame fully transparent (GIF alpha is
    /// 1-bit, so premultiplied zeros — colour and alpha — are the only honest encoding).
    private func makeGIF(at url: URL, w: Int, h: Int, frames: Int, transparent: Bool = false) throws {
        let dst = CGImageDestinationCreateWithURL(url as CFURL,
                                                  UTType.gif.identifier as CFString, frames, nil)!
        for i in 0..<frames {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let o = (y * w + x) * 4
                if transparent, x >= w / 2 { continue }          // stays 0,0,0,0
                bytes[o] = UInt8((x * 255 / w + i * 19) % 256)
                bytes[o + 1] = UInt8((y * 255 / h + i * 7) % 256)
                bytes[o + 2] = UInt8((i * 31) % 256)
                bytes[o + 3] = 255
            } }
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast
                                                         : CGImageAlphaInfo.noneSkipLast).rawValue)!
            CGImageDestinationAddImage(dst, ctx.makeImage()!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(dst)
    }

    func testAnimatedGIFConvertsToWebMP4() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifconv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("anim.gif")
        try makeGIF(at: src, w: 160, h: 120, frames: 30)

        let forge = ForgeOptimizer()
        var results: [OptimizeResult] = []
        for try await r in try forge.webOptimize(.url(src), to: .directory(tmp), Options()) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else {
            return XCTFail("animated GIF must convert (got \(r.status))")
        }
        XCTAssertEqual(r.kind, .video, "the deliverable governs the kind")
        XCTAssertEqual(r.outputType, .mpeg4Movie)
        XCTAssertEqual(r.recipe.codec, "H.264")
        guard case .file(let out) = r.output else { return XCTFail("expected .file") }
        XCTAssertEqual(out.pathExtension, "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    /// The GIF→mp4 route is the one place the Kit knowingly flattens transparency (over white, the
    /// web-background convention) while alpha VIDEO is refused outright — so the flatten must be
    /// on the receipt: it is invisible in the bytes and to the scorer.
    func testTransparentAnimatedGIFReceiptsTheFlatten() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifalpha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("sticker.gif")
        try makeGIF(at: src, w: 160, h: 120, frames: 12, transparent: true)

        var results: [OptimizeResult] = []
        for try await r in try ForgeOptimizer().webOptimize(.url(src), to: .directory(tmp), Options()) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else {
            return XCTFail("a transparent animated GIF still converts (got \(r.status))")
        }
        XCTAssertTrue(r.recipe.flattenedAlpha, "the flatten must be receipted: \(r.recipe)")
        XCTAssertTrue(r.recipe.description.contains("alpha-flattened"), r.recipe.description)

        // And an OPAQUE GIF must not claim a flatten it never performed.
        let opaque = tmp.appendingPathComponent("opaque.gif")
        try makeGIF(at: opaque, w: 160, h: 120, frames: 12)
        var opaqueResults: [OptimizeResult] = []
        for try await r in try ForgeOptimizer().webOptimize(.url(opaque), to: .directory(tmp), Options()) {
            opaqueResults.append(r)
        }
        XCTAssertFalse(try XCTUnwrap(opaqueResults.first).recipe.flattenedAlpha)
    }

    func testSingleFrameGIFStaysInTheStillRace() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifstill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("still.gif")
        try makeGIF(at: src, w: 160, h: 120, frames: 1)

        let forge = ForgeOptimizer()
        var results: [OptimizeResult] = []
        for try await r in try forge.webOptimize(.url(src), to: .directory(tmp), Options()) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else {
            return XCTFail("single-frame GIF must optimize as a still (got \(r.status))")
        }
        XCTAssertEqual(r.kind, .image)
        XCTAssertTrue(r.outputType == .png || r.outputType == .jpeg,
                      "a still GIF ships as a web still, never video (got \(String(describing: r.outputType)))")
    }
}
