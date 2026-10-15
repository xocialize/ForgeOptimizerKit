import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// `UpscaleTier.instant` — the efficiency tier (0.25.0, AB-D-0146; ForgeCore runs Anime4K VL on Metal shaders).
///
/// What these pin: it is neither still-only nor video-only and is spelled for receipts; a still records the tier and
/// model the enhancer REPORTED; a clip runs it frame by frame instead of refusing it; an enhancer that predates the tier
/// refuses it by default and the item fails with that reason; the reasons that list the
/// tiers a still or a clip can take name it.
final class InstantTierTests: XCTestCase {

    func testInstantIsNeitherStillOnlyNorVideoOnly() {
        XCTAssertFalse(UpscaleTier.instant.isStillOnly)
        XCTAssertFalse(UpscaleTier.instant.isVideoOnly)
        XCTAssertEqual(UpscaleTier.instant.rawValue, "instant")
        XCTAssertEqual(UpscaleTier(rawValue: "instant"), .instant)
        XCTAssertTrue(UpscaleTier.allCases.contains(.instant))
    }

    func testStillRecordsTheReportedTierAndModel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(width: 64, height: 48, to: src)
        let enhancer = TieredEnhancer()
        var result: OptimizeResult?
        for await r in try ForgeOptimizer(enhancer: enhancer)
            .optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                      Options(quality: .balanced, enhance: .on, upscale: .x2, upscaleTier: .instant)) {
            result = r
        }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(enhancer.calls.count, 1)
        XCTAssertEqual(r.recipe.upscaleTier, .instant)
        XCTAssertEqual(r.recipe.upscaleModel, TieredEnhancer.model(for: .instant))
        XCTAssertNil(r.recipe.upscaleTierRequested)
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(r)))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["upscale_tier"] as? String, "instant")
    }

    /// A clip is not refused: Instant runs per frame like Fast and Best, and the delivered clip is twice the size.
    func testClipRunsInstantFrameByFrame() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 6, audio: false)
        let enhancer = TieredEnhancer()
        var result: OptimizeResult?
        for await r in try ForgeOptimizer(enhancer: enhancer, flowProvider: ZeroFlowProvider())
            .optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                      Options(quality: .aggressive, upscale: .x2, upscaleTier: .instant)) {
            result = r
        }
        let r = try XCTUnwrap(result)
        guard case .file(let delivered) = r.output else { return XCTFail("expected a delivered clip, got \(r.status)") }
        XCTAssertGreaterThan(enhancer.calls.count, 0, "frames went through the enhancer")
        XCTAssertEqual(r.recipe.upscaleTier, .instant)
        let tracks = try await AVURLAsset(url: delivered).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 128)
        XCTAssertEqual(Int(size.height), 96)
    }

    /// An enhancer that predates the tier refuses it through the protocol default, and the item fails with that reason
    /// instead of running another tier.
    func testEnhancerWithoutTheTierRefusesIt() async throws {
        let enhancer = FixedScaleEnhancer(factor: 2)
        let availability = await enhancer.availability(of: .instant)
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.unavailableReason, "this enhancer offers no instant tier")

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(width: 64, height: 48, to: src)
        var result: OptimizeResult?
        for await r in try ForgeOptimizer(enhancer: enhancer)
            .optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                      Options(quality: .balanced, enhance: .on, upscale: .x2, upscaleTier: .instant)) {
            result = r
        }
        let r = try XCTUnwrap(result)
        XCTAssertNil(r.recipe.upscaleTier)
        XCTAssert("\(r.status)".contains("no instant tier"), "\(r.status)")
    }

    func testReasonsNameInstantAmongTheTiersOnOffer() {
        XCTAssert(UpscaleTier.liveActionStillReason.contains("Instant"))
        XCTAssert(UpscaleTier.generativeClipReason.contains("Instant"))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-instant-\(UUID().uuidString)")
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
