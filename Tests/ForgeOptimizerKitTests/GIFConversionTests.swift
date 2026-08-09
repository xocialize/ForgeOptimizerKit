import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// The Kit's GIF routing: animated GIFs on the web profile convert to H.264 mp4 through the
/// standard floor search; single-frame GIFs stay in the still race like any other image.
final class GIFConversionTests: XCTestCase {

    private func makeGIF(at url: URL, w: Int, h: Int, frames: Int) throws {
        let dst = CGImageDestinationCreateWithURL(url as CFURL,
                                                  UTType.gif.identifier as CFString, frames, nil)!
        for i in 0..<frames {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let o = (y * w + x) * 4
                bytes[o] = UInt8((x * 255 / w + i * 19) % 256)
                bytes[o + 1] = UInt8((y * 255 / h + i * 7) % 256)
                bytes[o + 2] = UInt8((i * 31) % 256)
                bytes[o + 3] = 255
            } }
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
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
