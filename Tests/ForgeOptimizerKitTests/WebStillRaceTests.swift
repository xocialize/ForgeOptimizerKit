import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// The web-still RACE wiring in the Kit: photo-like content ships .jpg with the floor on the
/// receipt; alpha ships .png with no floor claim (JPEG has no alpha — the race never runs).
/// The race MECHANICS (which format wins on which content) are pinned in media-bridge; these
/// tests pin the Kit's plumbing — extension, UTType, recipe honesty, alpha gate.
final class WebStillRaceTests: XCTestCase {

    /// Photo-like: smooth low-frequency structure + mild grain (periodic patterns are
    /// PNG-friendly and pure entropy is floor-hostile — neither is a photo; see media-bridge's
    /// race tests for the measured taxonomy).
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
        let dst = CGImageDestinationCreateWithURL(url as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, image, nil)
        CGImageDestinationFinalize(dst)
    }

    func testPhotoLikeStillShipsJPEGWithFloorOnReceipt() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("photo.png")
        try writePNG(makePhotoImage(256), to: src)

        let forge = ForgeOptimizer()
        var results: [OptimizeResult] = []
        for try await r in try forge.webOptimize(.url(src), to: .directory(tmp), Options()) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else {
            return XCTFail("photo-like still must optimize (got \(r.status))")
        }
        XCTAssertEqual(r.outputType, .jpeg, "photo-like content must win the race as JPEG")
        XCTAssertTrue(r.recipe.description.contains("JPEG"), "receipt names the codec: \(r.recipe)")
        XCTAssertEqual(r.recipe.qualityFloor, Options().quality.floor,
                       "the lossy winner carries the floor it met")
        if case .file(let out) = r.output {
            XCTAssertEqual(out.pathExtension, "jpg")
        } else {
            XCTFail("expected a file deliverable")
        }
    }

    /// Opaque-RGBA (screenshots, decoded frames): the channel exists, no pixel uses it — the JPEG
    /// race MUST still run. This is the exact shape that silently benched the race on a real 6 MP
    /// frame (2.3 MB PNG shipped where JPEG@floor measured 0.5 MB).
    func testOpaqueRGBAStillRacesIntoJPEG() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("race-o-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // alpha: true builds premultipliedLast; overwrite every alpha byte to opaque via the
        // fixture's alpha:false content drawn INTO an alpha-carrying context.
        let opaqueRGBA: CGImage = {
            let base = makePhotoImage(256)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            return ctx.makeImage()!
        }()
        XCTAssertTrue([.premultipliedLast, .premultipliedFirst, .first, .last]
            .contains(opaqueRGBA.alphaInfo), "fixture must CARRY an alpha channel")
        let src = tmp.appendingPathComponent("opaque-rgba.png")
        try writePNG(opaqueRGBA, to: src)

        let forge = ForgeOptimizer()
        var results: [OptimizeResult] = []
        for try await r in try forge.webOptimize(.url(src), to: .directory(tmp), Options()) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status else {
            return XCTFail("opaque-RGBA photo must optimize (got \(r.status))")
        }
        XCTAssertEqual(r.outputType, .jpeg, "an unused alpha channel must not bench the race")
    }

    func testAlphaStillStaysPNG() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("race-a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("photo-alpha.png")
        try writePNG(makePhotoImage(256, alpha: true), to: src)

        let forge = ForgeOptimizer()
        var results: [OptimizeResult] = []
        for try await r in try forge.webOptimize(.url(src), to: .directory(tmp), Options()) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        // An alpha PNG source may honestly skip (already web-native and the re-encode isn't
        // smaller) or deliver a PNG — either way it must NEVER become JPEG.
        XCTAssertNotEqual(r.outputType, .jpeg, "transparency must never race into JPEG")
        if case .optimized = r.status {
            XCTAssertEqual(r.outputType, .png)
            XCTAssertNil(r.recipe.qualityFloor, "PNG is lossless — no floor claim")
        }
    }
}
