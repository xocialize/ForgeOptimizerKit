import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// `UpscaleTier.generative` / `.generativeClean` — the generative stills tiers (AB-D-0111; ForgeCore runs VOSR2 and
/// Nacre behind a text-legibility guard).
///
/// What these pin: both are stills-only and spelled for receipts; a still records the tier, the model and the guard
/// route the enhancer REPORTED (a guard that composited two models is named as two); a clip asked for one fails
/// before any frame runs; an enhancer that predates the tiers refuses them by default; a quality conform takes them.
final class GenerativeTierTests: XCTestCase {

    func testGenerativeTiersAreStillOnlyAndSpelledForReceipts() {
        XCTAssertTrue(UpscaleTier.generative.isStillOnly)
        XCTAssertTrue(UpscaleTier.generativeClean.isStillOnly)
        XCTAssertFalse(UpscaleTier.generative.isVideoOnly)
        XCTAssertFalse(UpscaleTier.fast.isStillOnly)
        XCTAssertFalse(UpscaleTier.liveAction.isStillOnly)
        XCTAssertEqual(UpscaleTier.generative.rawValue, "generative")
        XCTAssertEqual(UpscaleTier.generativeClean.rawValue, "generative-clean")
    }

    /// A still on the provenance-clean tier whose guard protected words: the recipe and the receipt carry the tier,
    /// both models and the route — what the enhancer reported, not the request.
    func testStillRecordsTheReportedModelsAndGuardRoute() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(width: 64, height: 48, to: src)
        let enhancer = GuardedStubEnhancer(route: "protectWords")
        var result: OptimizeResult?
        for await r in try ForgeOptimizer(enhancer: enhancer)
            .optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                      Options(quality: .balanced, enhance: .on, upscale: .x2, upscaleTier: .generativeClean)) {
            result = r
        }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(enhancer.calls.count, 1)
        XCTAssertEqual(r.recipe.upscaleTier, .generativeClean)
        XCTAssertEqual(r.recipe.upscaleModel, "Nacre + NERVE (protected words)")
        XCTAssertEqual(r.recipe.upscaleGuardRoute, "protectWords")
        XCTAssertNil(r.recipe.upscaleTierRequested)
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(r)))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["upscale_tier"] as? String, "generative-clean")
        XCTAssertEqual(parsed["upscale_model"] as? String, "Nacre + NERVE (protected words)")
        XCTAssertEqual(parsed["upscale_guard_route"] as? String, "protectWords")
    }

    /// A non-generative tier reports no route, so the receipt carries no route key.
    func testNonGenerativeTierHasNoGuardRoute() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(width: 64, height: 48, to: src)
        var result: OptimizeResult?
        for await r in try ForgeOptimizer(enhancer: TieredEnhancer())
            .optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                      Options(quality: .balanced, enhance: .on, upscale: .x2, upscaleTier: .best)) {
            result = r
        }
        let r = try XCTUnwrap(result)
        XCTAssertNil(r.recipe.upscaleGuardRoute)
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(r)))
        XCTAssertFalse(line.contains("upscale_guard_route"), line)
    }

    /// Frame-by-frame generation has no temporal model: a clip asked for a generative tier fails with the reason,
    /// and not one frame reaches the enhancer.
    func testClipAskedForAGenerativeTierFailsBeforeAnyFrame() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 4, audio: false)
        let enhancer = GuardedStubEnhancer(route: "generative")
        for tier in [UpscaleTier.generative, .generativeClean] {
            var result: OptimizeResult?
            for await r in try ForgeOptimizer(enhancer: enhancer, flowProvider: ZeroFlowProvider())
                .optimize(.url(src), to: .directory(dir.appendingPathComponent(tier.rawValue)),
                          Options(quality: .aggressive, upscale: .x2, upscaleTier: tier)) {
                result = r
            }
            let r = try XCTUnwrap(result)
            guard case .failed(let why) = r.status else { XCTFail("\(tier): expected a failed item, got \(r.status)"); continue }
            XCTAssertEqual(why, "upscale tier '\(tier.rawValue)' unavailable: " + UpscaleTier.generativeClipReason)
        }
        XCTAssertEqual(enhancer.calls.count, 0, "no frame went through the enhancer")
    }

    /// An enhancer that predates the generative tiers refuses them by the protocol default — never runs another.
    func testAnEnhancerWithoutGenerativeTiersRefusesThem() async {
        for tier in [UpscaleTier.generative, .generativeClean] {
            let verdict = await FixedScaleEnhancer(factor: 2).availability(of: tier)
            XCTAssertFalse(verdict.isAvailable, "\(tier)")
        }
    }

    /// A quality conform takes a generative tier through the upscale-only path, and names what ran.
    func testQualityConformTakesAGenerativeTier() async throws {
        let image = try makeImage(width: 40, height: 30)
        let forge = ForgeOptimizer(enhancer: GuardedStubEnhancer(route: "generative"))
        let r = try await forge.conform(image, to: MediaSpec(size: .fit(maxWidth: 80, maxHeight: 60)),
                                        quality: .quality(.generative))
        XCTAssertEqual(r.upscaleTier, .generative)
        XCTAssertEqual(r.upscaleModel, "VOSR2")
        XCTAssertEqual(r.modelScale, 2)
        XCTAssertEqual(r.image.width, 80)
        XCTAssertEqual(r.image.height, 60)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-gen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeImage(width w: Int, height h: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func writePNG(width w: Int, height h: Int, to url: URL) throws {
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dst, try makeImage(width: w, height: h), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
    }
}

/// The generative tiers with ForgeCore's shape: each tier names its model, and a guard that protected words names
/// both models and reports the route. Serves `enhanceReporting` and the upscale-only `upscaleReporting`.
struct GuardedStubEnhancer: ImageEnhancer {
    let route: String
    let calls = CallCounter()

    static func model(for tier: UpscaleTier, route: String) -> String {
        let generative = tier == .generativeClean ? "Nacre" : "VOSR2"
        return route == "protectWords" ? "\(generative) + NERVE (protected words)" : generative
    }

    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        try await enhanceReporting(image, options: options).image
    }

    func enhanceReporting(_ image: CGImage, options: Options) async throws -> EnhanceOutcome {
        calls.increment()
        let factor: Int = switch options.upscale { case .none: 1; case .x2: 2; case .x4: 4 }
        guard factor > 1 else { return EnhanceOutcome(image: image) }
        let scaled = try await FixedScaleEnhancer(factor: factor).enhance(image, options: options)
        return EnhanceOutcome(image: scaled, upscaleTier: options.upscaleTier,
                              upscaleModel: Self.model(for: options.upscaleTier, route: route), upscaleRoute: route)
    }

    func upscaleReporting(_ image: CGImage, factor: UpscaleFactor, tier: UpscaleTier) async throws -> EnhanceOutcome {
        calls.increment()
        let f: Int = switch factor { case .none: 1; case .x2: 2; case .x4: 4 }
        let scaled = try await FixedScaleEnhancer(factor: f).enhance(image, options: Options(quality: .balanced))
        return EnhanceOutcome(image: scaled, upscaleTier: tier, upscaleModel: Self.model(for: tier, route: route),
                              upscaleRoute: route)
    }

    func availability(of tier: UpscaleTier) async -> UpscaleTierAvailability {
        tier.isStillOnly ? .available(tier, model: Self.model(for: tier, route: route))
                         : .unavailable(tier, reason: "this stub serves the generative tiers only")
    }
}
