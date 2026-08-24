import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// `Options.output` + `Options.stripMetadata` honored (they were stored-but-unread — silent no-ops
/// in a public API). Coverage is deliberately CPU-only (PNG/JPEG via ImageIO): the HEIC pin shares
/// the exact routing shape but its encode runs the VideoToolbox hardware encoder, quarantined on
/// this macOS beta (LESSONS.md); same for the video strip paths.
final class OutputOptionsTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-outopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    // MARK: - Fixtures

    /// Photo-like content (smooth structure + grain) so the JPEG lane is competitive — same shape
    /// as the race tests' fixture. `grain: false` = smooth-only, for tests that need a q1.0 source
    /// to re-encode DETERMINISTICALLY smaller at the floor (grain at 128² is incompressible enough
    /// to defeat even a max-quality source on size).
    private func makePhotoImage(_ w: Int, _ h: Int, alpha: Bool = false,
                                grain grainOn: Bool = true) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 0x9E3779B9
        func grain() -> Double {
            guard grainOn else { return 0 }
            seed = seed &* 1664525 &+ 1013904223
            return Double(Int32(truncatingIfNeeded: seed >> 8) % 13) - 6
        }
        for y in 0..<h { for x in 0..<w {
            let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
            let l1 = 110 + 70 * sin(fx * 4.1 + 0.6) * cos(fy * 2.9 + 1.1)
            let l2 = 40 * sin((fx + fy) * 6.3)
            let i = (y * w + x) * 4
            bytes[i]     = UInt8(clamping: Int(l1 + l2 * 0.7 + grain()))
            bytes[i + 1] = UInt8(clamping: Int(l1 * 0.9 + l2 + grain()))
            bytes[i + 2] = UInt8(clamping: Int(l1 * 1.1 + l2 * 0.4 + grain()))
            bytes[i + 3] = alpha && x < w / 2 ? 128 : 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs, bitmapInfo: info.rawValue)!
        return ctx.makeImage()!
    }

    private func write(_ image: CGImage, as type: UTType, to url: URL,
                       properties: [CFString: Any]? = nil) throws {
        let dst = CGImageDestinationCreateWithURL(url as CFURL,
                                                  type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, image, properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(dst), "fixture write must succeed")
    }

    /// EXIF + GPS payload a strip must shed and a preserve must carry.
    private var exifFixture: [CFString: Any] {
        [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:10 12:00:00",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 47.6062,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.3321,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
        ]
    }

    private func properties(of url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return [:] }
        return props
    }

    private func firstResult(_ stream: AsyncStream<OptimizeResult>) async -> OptimizeResult? {
        var results: [OptimizeResult] = []
        for await r in stream { results.append(r) }
        return results.first
    }

    private func outputURL(_ r: OptimizeResult, file: StaticString = #filePath,
                           line: UInt = #line) throws -> URL {
        guard case .file(let u) = r.output else {
            XCTFail("expected a file deliverable, got \(r.output)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return u
    }

    // MARK: - Format routing (stills)

    func testNativePinPNGConverts() async throws {
        let src = tmp.appendingPathComponent("photo.jpg")
        try write(makePhotoImage(128, 128), as: .jpeg, to: src)
        let forge = ForgeOptimizer()
        let r = try await firstResult(
            try forge.optimize(.url(src), to: .directory(tmp), Options(output: .png)))
        let result = try XCTUnwrap(r)
        // Conversion semantics: a PNG of a photo is LARGER than the JPEG source, and it must
        // still deliver — the caller asked for the format, not for a size win.
        guard case .optimized = result.status else {
            return XCTFail("explicit .png must deliver as a conversion (got \(result.status))")
        }
        XCTAssertEqual(result.outputType, .png)
        XCTAssertEqual(try outputURL(result).pathExtension, "png")
        XCTAssertTrue(result.recipe.description.contains("PNG"), "\(result.recipe)")
        XCTAssertNil(result.recipe.qualityFloor, "PNG is lossless — no floor claim")
    }

    func testNativePinJPEGConverts() async throws {
        let src = tmp.appendingPathComponent("photo.png")
        try write(makePhotoImage(128, 128), as: .png, to: src)
        let forge = ForgeOptimizer()
        let r = try await firstResult(
            try forge.optimize(.url(src), to: .directory(tmp), Options(output: .jpeg)))
        let result = try XCTUnwrap(r)
        guard case .optimized = result.status else {
            return XCTFail("explicit .jpeg must deliver as a conversion (got \(result.status))")
        }
        XCTAssertEqual(result.outputType, .jpeg)
        XCTAssertEqual(try outputURL(result).pathExtension, "jpg")
        XCTAssertEqual(result.recipe.qualityFloor, Options().quality.floor,
                       "the lossy pin carries the floor it searched against")
        XCTAssertNotNil(result.after.qualityScore, "the achieved score rides the receipt")
    }

    func testWebPinPNGSuppressesRace() async throws {
        // Photo content would win the race as JPEG; the explicit .png pin must bench that lane.
        let src = tmp.appendingPathComponent("photo.jpg")
        try write(makePhotoImage(128, 128), as: .jpeg, to: src)
        let forge = ForgeOptimizer()
        let r = try await firstResult(
            try forge.webOptimize(.url(src), to: .directory(tmp), Options(output: .png)))
        let result = try XCTUnwrap(r)
        guard case .optimized = result.status else {
            return XCTFail("jpeg→png is a conversion — must deliver (got \(result.status))")
        }
        XCTAssertEqual(result.outputType, .png, "the pin overrides the race outcome")
    }

    // MARK: - Invalid pairings fail the item (never silently reinterpreted)

    private func assertFails(_ r: OptimizeResult?, containing needle: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("no result", file: file, line: line) }
        guard case .failed(let why) = r.status else {
            return XCTFail("expected .failed, got \(r.status)", file: file, line: line)
        }
        XCTAssertTrue(why.contains(needle), "reason '\(why)' must mention '\(needle)'",
                      file: file, line: line)
    }

    func testHEVCPinOnStillFails() async throws {
        let src = tmp.appendingPathComponent("still.png")
        try write(makePhotoImage(64, 64), as: .png, to: src)
        let r = try await firstResult(
            try ForgeOptimizer().optimize(.url(src), to: .directory(tmp), Options(output: .hevc)))
        assertFails(r, containing: "video codec")
    }

    func testStillPinOnVideoFails() async throws {
        // Validation runs before any decode/probe — the file only needs a video extension.
        let src = tmp.appendingPathComponent("clip.mp4")
        try Data("not a real mp4".utf8).write(to: src)
        let r = try await firstResult(
            try ForgeOptimizer().optimize(.url(src), to: .directory(tmp), Options(output: .jpeg)))
        assertFails(r, containing: "stills format")
    }

    func testHEICPinOnWebFails() async throws {
        let src = tmp.appendingPathComponent("still.png")
        try write(makePhotoImage(64, 64), as: .png, to: src)
        let r = try await firstResult(
            try ForgeOptimizer().webOptimize(.url(src), to: .directory(tmp), Options(output: .heic)))
        assertFails(r, containing: "web-universal")
    }

    func testJPEGPinRefusesRealTransparency() async throws {
        let src = tmp.appendingPathComponent("alpha.png")
        try write(makePhotoImage(64, 64, alpha: true), as: .png, to: src)
        let r = try await firstResult(
            try ForgeOptimizer().optimize(.url(src), to: .directory(tmp), Options(output: .jpeg)))
        assertFails(r, containing: "transparency")
    }

    func testOptionsPinConflictingWithHostPinnedURLFails() async throws {
        let src = tmp.appendingPathComponent("photo.jpg")
        try write(makePhotoImage(64, 64), as: .jpeg, to: src)
        let req = OptimizeRequest(input: src, output: tmp.appendingPathComponent("out.png"),
                                  options: Options(output: .jpeg))
        let r = await firstResult(ForgeOptimizer().webOptimize([req]))
        assertFails(r, containing: "conflicts")
    }

    func testAnimatedGIFRefusesStillPin() async throws {
        let src = tmp.appendingPathComponent("anim.gif")
        let dst = CGImageDestinationCreateWithURL(src as CFURL,
                                                  UTType.gif.identifier as CFString, 2, nil)!
        let frameProps = [kCGImagePropertyGIFDictionary:
                            [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(dst, makePhotoImage(32, 32), frameProps)
        CGImageDestinationAddImage(dst, makePhotoImage(32, 32), frameProps)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        // Thrown before the mezzanine render — no video encode runs for this refusal.
        let r = try await firstResult(
            try ForgeOptimizer().webOptimize(.url(src), to: .directory(tmp), Options(output: .png)))
        assertFails(r, containing: "animated")
    }

    // MARK: - stripMetadata (preserve is the declared default; strip is the guarantee)

    func testMetadataPreservedByDefault() async throws {
        let src = tmp.appendingPathComponent("meta.jpg")
        var props = exifFixture
        props[kCGImageDestinationLossyCompressionQuality] = 1.0   // headroom so the search shrinks
        // Smooth content: the q1.0 source re-encodes reliably smaller at the floor, so this
        // exercises preserve on a NORMAL delivery (no forced-delivery machinery involved).
        try write(makePhotoImage(128, 128, grain: false), as: .jpeg, to: src, properties: props)

        let r = try await firstResult(try ForgeOptimizer().webOptimize(
            .url(src), to: .directory(tmp), Options(output: .jpeg)))
        let result = try XCTUnwrap(r)
        guard case .optimized = result.status else {
            return XCTFail("q1.0 source must re-encode smaller at the floor (got \(result.status))")
        }
        let out = properties(of: try outputURL(result))
        let exif = out[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let gps = out[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertNotNil(exif?[kCGImagePropertyExifDateTimeOriginal as String],
                        "default (stripMetadata: false) must CARRY the source EXIF")
        let lat = try XCTUnwrap(gps?[kCGImagePropertyGPSLatitude as String] as? Double,
                                "GPS must carry too — preserve is all-or-nothing")
        XCTAssertEqual(lat, 47.6062, accuracy: 0.001)
        XCTAssertFalse(result.recipe.strippedMetadata,
                       "no strip ran — the receipt must not claim one")
    }

    func testStripMetadataShedsEXIFAndGPS() async throws {
        let src = tmp.appendingPathComponent("meta.jpg")
        try write(makePhotoImage(128, 128), as: .jpeg, to: src, properties: exifFixture)

        let r = try await firstResult(try ForgeOptimizer().webOptimize(
            .url(src), to: .directory(tmp), Options(output: .jpeg, stripMetadata: true)))
        let result = try XCTUnwrap(r)
        // A metadata-carrying source must DELIVER under strip even when the re-encode isn't
        // smaller — a skip would keep the original, metadata and all.
        guard case .optimized = result.status else {
            return XCTFail("strip on a metadata source must deliver (got \(result.status))")
        }
        let out = properties(of: try outputURL(result))
        let exif = out[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String],
                     "EXIF must be shed: \(exif ?? [:])")
        XCTAssertNil(out[kCGImagePropertyGPSDictionary as String],
                     "GPS must be shed — it is the privacy half of the guarantee")
        XCTAssertTrue(result.recipe.strippedMetadata, "the receipt carries the strip claim")
        XCTAssertTrue(result.recipe.description.contains("strip-metadata"), "\(result.recipe)")
    }

    // MARK: - Orientation is baked into pixels (both modes)

    func testOrientationBakesUprightAndTagIsDropped() async throws {
        // 128×64 stored, EXIF orientation 6 (rotate 90° CW to display) → renders 64×128. The old
        // pipeline decoded as-stored and wrote no tag: the deliverable shipped SIDEWAYS.
        let src = tmp.appendingPathComponent("rotated.jpg")
        try write(makePhotoImage(128, 64), as: .jpeg, to: src,
                  properties: [kCGImagePropertyOrientation: 6])

        // The .png pin makes delivery deterministic (jpeg→png is a conversion) — the assertions
        // are about the bake, not the race.
        let r = try await firstResult(try ForgeOptimizer().webOptimize(
            .url(src), to: .directory(tmp), Options(output: .png)))
        let result = try XCTUnwrap(r)
        guard case .optimized = result.status else {
            return XCTFail("rotated source must deliver (got \(result.status))")
        }
        XCTAssertEqual(result.after.width, 64, "receipt describes the upright image")
        XCTAssertEqual(result.after.height, 128)
        let out = properties(of: try outputURL(result))
        XCTAssertEqual(out[kCGImagePropertyPixelWidth as String] as? Int, 64,
                       "pixels themselves are upright in the deliverable")
        XCTAssertEqual(out[kCGImagePropertyPixelHeight as String] as? Int, 128)
        let orientation = out[kCGImagePropertyOrientation as String] as? UInt32
        XCTAssertTrue(orientation == nil || orientation == 1,
                      "no stale rotation tag may ride along (got \(String(describing: orientation)))")
    }
}
