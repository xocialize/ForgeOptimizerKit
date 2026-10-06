import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import ForgeOptimizerKit

/// BRIDGE-062. The receipt used to report `options.upscale` — what the caller *asked for*. That is
/// accurate only while every model honours every request, which is a property of today's models rather
/// than of the code.
///
/// BRIDGE-040 is the case that proves it: a fixed-4× model asked for 2× produced 4× pixels while the
/// receipt said 2×. These lock the fix by driving the exact divergences a request-based tag cannot see.
final class UpscaleHonestyTests: XCTestCase {

    private func recipe(from before: Int, to after: Int, requested: UpscaleFactor) -> AppliedRecipe {
        var r = AppliedRecipe()
        r.setUpscale(measuredFrom: before, to: after, requested: requested)
        return r
    }

    func testHonouredRequestReportsTheFactorWithNoNoise() {
        let r = recipe(from: 512, to: 1024, requested: .x2)
        XCTAssertEqual(r.upscaled, 2)
        XCTAssertNil(r.upscaleRequested, "no divergence to report when the model did as asked")
        XCTAssertTrue(r.description.contains("upscale×2"))
        XCTAssertFalse(r.description.contains("asked"))
    }

    /// The original BRIDGE-040 defect: asked 2×, got 4×. The receipt must say 4 and show the divergence.
    func testFixedFourTimesModelAskedForTwoReportsFourAndSaysSo() {
        let r = recipe(from: 512, to: 2048, requested: .x2)
        XCTAssertEqual(r.upscaled, 4, "must report the pixels that exist, not the request")
        XCTAssertEqual(r.upscaleRequested, 2)
        XCTAssertTrue(r.description.contains("upscale×4 (asked ×2)"), r.description)
    }

    /// The inverse lie: an upscale was requested and did not happen. Reporting the request here would
    /// claim an enhancement that is not in the file.
    func testRequestedButNotAppliedReportsNoUpscale() {
        let r = recipe(from: 512, to: 512, requested: .x2)
        XCTAssertNil(r.upscaled, "no upscale in the pixels means no upscale in the receipt")
        XCTAssertEqual(r.upscaleRequested, 2, "but the unmet request is still surfaced")
        XCTAssertFalse(r.description.contains("upscale×"), r.description)
    }

    func testNoUpscaleRequestedAndNoneApplied() {
        let r = recipe(from: 512, to: 512, requested: .none)
        XCTAssertNil(r.upscaled)
        XCTAssertNil(r.upscaleRequested)
    }

    /// Degenerate input must not fabricate a factor.
    func testZeroWidthsDoNotInventAnUpscale() {
        XCTAssertNil(recipe(from: 0, to: 1024, requested: .x2).upscaled)
        XCTAssertNil(recipe(from: 512, to: 0, requested: .x2).upscaled)
    }

    /// Rounding tolerance: an encoder nudging 1024→1026 for macroblock alignment is not a 1× upscale
    /// claim, and a real 2× that lands a pixel off is still 2×.
    func testToleratesAlignmentNudgesWithoutMisreporting() {
        XCTAssertNil(recipe(from: 1024, to: 1026, requested: .none).upscaled)
        XCTAssertEqual(recipe(from: 512, to: 1023, requested: .x2).upscaled, 2)
    }

    // MARK: - Through the call sites, not just the helper

    // The tests above drive `setUpscale` directly. Every other end-to-end upscale test uses a model
    // that honours ×2, where request and result agree — so a call site regressing to
    // `options.upscale` would pass all of them. These drive the divergence through `optimize` /
    // `webOptimize` and hold the receipt to the delivered file, never to the Kit's own bookkeeping.

    /// The corpus case (AB-T-0013): a real signage still, a model that returns 4× when asked for 2×.
    /// `FORGE_CORPUS` unset → skip, per the corpus README (media-bridge's corpus harness does the same).
    ///
    ///   FORGE_CORPUS=/…/training-resources/Corpus swift test --filter UpscaleHonestyTests
    func testCorpusStillAskedForTwoGotFourReceiptsFour() async throws {
        guard let corpus = ProcessInfo.processInfo.environment["FORGE_CORPUS"], !corpus.isEmpty else {
            throw XCTSkip("FORGE_CORPUS unset — corpus case skipped")
        }
        let src = URL(fileURLWithPath: corpus).appendingPathComponent("derived/320/stills/KEYNOTE_graphic.png")
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("no \(src.path)") }
        try await assertStillAskedForTwoReceiptsFour(src)
    }

    /// The same still divergence on a synthetic image, so CI — which has no corpus — locks it too.
    func testStillAskedForTwoGotFourReceiptsFour() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(64, 48), to: src)
        try await assertStillAskedForTwoReceiptsFour(src)
    }

    /// Both video call sites: native (the SR pipeline's HEVC is the deliverable) and web (that
    /// intermediate re-encoded to H.264). Each must measure the file it delivered.
    func testVideoAskedForTwoGotFourReceiptsFourOnBothProfiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeGradientClip(to: src, w: 64, h: 48, frames: 4)
        let forge = ForgeOptimizer(enhancer: FixedScaleEnhancer(factor: 4), flowProvider: ZeroFlowProvider())
        let ask = Options(quality: .aggressive, upscale: .x2)

        for profile in ["native", "web"] {
            let out = dir.appendingPathComponent(profile)
            let stream = profile == "web"
                ? try forge.webOptimize(.url(src), to: .directory(out), ask)
                : try forge.optimize(.url(src), to: .directory(out), ask)
            var result: OptimizeResult?
            for await r in stream { result = r }
            let r = try XCTUnwrap(result, profile)
            guard case .file(let delivered) = r.output else {
                XCTFail("\(profile): expected a delivered file, got \(r.status)"); continue
            }
            let track = try await AVURLAsset(url: delivered).loadTracks(withMediaType: .video).first
            let size = try await XCTUnwrap(track, profile).load(.naturalSize)
            XCTAssertEqual(Int(size.width), 4 * 64, "\(profile): the model returned 4×, whatever was asked")
            XCTAssertEqual(Int(size.height), 4 * 48, profile)
            XCTAssertEqual(r.recipe.upscaled, 4, "\(profile): the tag follows the file")
            XCTAssertEqual(r.recipe.upscaleRequested, 2, "\(profile): the unhonoured request stays visible")
            XCTAssertTrue(String(describing: r.recipe).contains("upscale×4 (asked ×2)"), "\(profile): \(r.recipe)")
        }
    }

    /// V4b's pipeline writes video only. Until 2026-10-05 its deliverable shipped silent on both profiles; the
    /// source's soundtrack must come back, as on the Live action route, and the receipt still describes the file.
    func testPerFrameVideoUpscaleKeepsTheSourceAudioOnBothProfiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeClip(to: src, w: 64, h: 48, frames: 15, audio: true)
        let forge = ForgeOptimizer(enhancer: TieredEnhancer(), flowProvider: ZeroFlowProvider())
        let ask = Options(quality: .aggressive, upscale: .x2)

        for profile in ["native", "web"] {
            let out = dir.appendingPathComponent(profile)
            let stream = profile == "web"
                ? try forge.webOptimize(.url(src), to: .directory(out), ask)
                : try forge.optimize(.url(src), to: .directory(out), ask)
            var result: OptimizeResult?
            for await r in stream { result = r }
            let r = try XCTUnwrap(result, profile)
            guard case .file(let delivered) = r.output else {
                XCTFail("\(profile): expected a delivered file, got \(r.status)"); continue
            }
            let asset = AVURLAsset(url: delivered)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1, "\(profile): the source's audio track came back")
            if let track = audio.first {
                let range = try await track.load(.timeRange)
                XCTAssertGreaterThan(range.duration.seconds, 0.3, "\(profile): real audio, not an empty track")
            }
            let video = try await asset.loadTracks(withMediaType: .video)
            let size = try await XCTUnwrap(video.first, profile).load(.naturalSize)
            XCTAssertEqual(Int(size.width), 2 * 64, profile)
            XCTAssertEqual(r.recipe.upscaled, 2, profile)
            XCTAssertEqual(r.recipe.upscaleModel, "FastModel", profile)
            XCTAssertEqual(r.recipe.codec, profile == "web" ? "H.264" : "HEVC", "\(profile): the codec in the file")
        }
    }

    /// `optimize` with the fixed-4× model asked for ×2, then the deliverable read back: the receipt —
    /// struct, prose and NDJSON — must describe what is in the file.
    private func assertStillAskedForTwoReceiptsFour(_ src: URL) async throws {
        let out = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let forge = ForgeOptimizer(enhancer: FixedScaleEnhancer(factor: 4))
        var results: [OptimizeResult] = []
        for await r in try forge.optimize(.url(src), to: .directory(out),
                                          Options(quality: .balanced, enhance: .on, upscale: .x2)) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)
        guard case .optimized = r.status, case .file(let delivered) = r.output else {
            return XCTFail("expected a delivered file, got \(r.status)")
        }

        // Both ends measured from the files themselves: the one witness that cannot be wrong.
        let source = try pixelSize(src), result = try pixelSize(delivered)
        XCTAssertEqual(result.w, 4 * source.w, "the model returned 4×, whatever was asked")
        XCTAssertEqual(result.h, 4 * source.h)
        XCTAssertEqual(r.after.width, result.w)
        XCTAssertEqual(r.after.height, result.h)

        XCTAssertEqual(r.recipe.upscaled, 4, "the tag follows the pixels")
        XCTAssertEqual(r.recipe.upscaleRequested, 2, "the unhonoured request stays visible")
        XCTAssertTrue(String(describing: r.recipe).contains("upscale×4 (asked ×2)"), "\(r.recipe)")

        // The NDJSON a host ingests says the same — checked after serialization, not before it.
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(r)))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let recipe = try XCTUnwrap(parsed["recipe"] as? String)
        XCTAssertTrue(recipe.contains("upscale×4 (asked ×2)"), recipe)
        let after = try XCTUnwrap(parsed["after"] as? [String: Any])
        XCTAssertEqual(after["width"] as? Int, result.w)
        XCTAssertEqual(after["height"] as? Int, result.h)
        // …and so do the structured keys, which a host should never have to parse out of the prose.
        XCTAssertEqual(parsed["upscaled"] as? Int, 4)
        XCTAssertEqual(parsed["upscale_requested"] as? Int, 2)
        XCTAssertNil(parsed["upscale_tier"], "a non-reporting enhancer names no tier — unknown, not guessed")
        XCTAssertNil(parsed["upscale_model"])
    }

    // MARK: - The tier and the model (AB-T-0187)

    // `Options.upscaleTier` picks the backer; the receipt names the tier and model the enhancer REPORTS
    // running. The same rule as the scale above, one field over: a tag copied from the request is right
    // only while every enhancer does exactly as asked.

    /// The helper, directly: the report wins, the request appears only when the report differs.
    func testBackerFieldsFollowTheReport() {
        var asked = Options(upscale: .x4, upscaleTier: .best)
        var r = AppliedRecipe()
        r.setUpscaleBacker(reportedTier: .best, reportedModel: "RealPLKSR", options: asked)
        XCTAssertEqual(r.upscaleTier, .best)
        XCTAssertEqual(r.upscaleModel, "RealPLKSR")
        XCTAssertNil(r.upscaleTierRequested, "no divergence to report")

        r.setUpscaleBacker(reportedTier: .fast, reportedModel: "NERVE", options: asked)
        XCTAssertEqual(r.upscaleTier, .fast, "the tier that ran, not the tier asked for")
        XCTAssertEqual(r.upscaleTierRequested, .best)

        r.setUpscaleBacker(reportedTier: nil, reportedModel: nil, options: asked)
        XCTAssertNil(r.upscaleTier, "nothing reported → nothing claimed, whatever was asked")
        XCTAssertNil(r.upscaleModel)
        XCTAssertNil(r.upscaleTierRequested, "an unreported tier is unknown, not a divergence")

        asked.upscale = .none
        r.setUpscaleBacker(reportedTier: .fast, reportedModel: "NERVE", options: asked)
        XCTAssertNil(r.upscaleTierRequested, "no upscale asked → no tier asked")
    }

    func testTierDefaultsToFastAndThreadsThroughThePresetInit() {
        XCTAssertEqual(Options().upscaleTier, .fast)
        XCTAssertEqual(Options(preset: .balanced, upscale: .x4, upscaleTier: .best).upscaleTier, .best)
    }

    /// End to end on a still: ask Best, the enhancer runs its best backer, and the struct, the prose
    /// and the NDJSON all name it.
    func testStillReceiptNamesTheTierAndModelThatRan() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(64, 48), to: src)

        let enhancer = TieredEnhancer()
        let r = try await optimizeOne(src, into: dir.appendingPathComponent("out"), enhancer: enhancer,
                                      Options(quality: .balanced, enhance: .on, upscale: .x2, upscaleTier: .best))
        guard case .optimized = r.status else { return XCTFail("expected a delivered file, got \(r.status)") }
        XCTAssertEqual(r.recipe.upscaled, 2)
        XCTAssertEqual(r.recipe.upscaleTier, .best)
        XCTAssertEqual(r.recipe.upscaleModel, "BestModel")
        XCTAssertNil(r.recipe.upscaleTierRequested)
        XCTAssertTrue(String(describing: r.recipe).contains("upscale×2 [best · BestModel]"), "\(r.recipe)")

        let parsed = try parsedReceipt(r)
        XCTAssertEqual(parsed["upscale_tier"] as? String, "best")
        XCTAssertEqual(parsed["upscale_model"] as? String, "BestModel")
        XCTAssertEqual(parsed["upscaled"] as? Int, 2)
        XCTAssertNil(parsed["upscale_tier_requested"])
    }

    /// An enhancer that claims Best, then runs Fast anyway. The receipt must say Fast ran and that
    /// Best was asked for — the receipt describes the file, not the promise.
    func testSubstitutedTierIsReportedAsWhatRanWithTheRequestVisible() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(64, 48), to: src)

        let r = try await optimizeOne(src, into: dir.appendingPathComponent("out"),
                                      enhancer: TieredEnhancer(substitute: .fast),
                                      Options(quality: .balanced, enhance: .on, upscale: .x2, upscaleTier: .best))
        XCTAssertEqual(r.recipe.upscaleTier, .fast)
        XCTAssertEqual(r.recipe.upscaleModel, "FastModel")
        XCTAssertEqual(r.recipe.upscaleTierRequested, .best)
        XCTAssertTrue(String(describing: r.recipe).contains("[fast · FastModel — asked best]"), "\(r.recipe)")
        XCTAssertEqual(try parsedReceipt(r)["upscale_tier_requested"] as? String, "best")
    }

    /// The no-silent-fallback rule: a tier the enhancer says it cannot run fails the item with the
    /// enhancer's own reason, before any model work — and nothing is written.
    func testUnavailableTierFailsTheItemWithItsReasonAndRunsNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(64, 48), to: src)
        let out = dir.appendingPathComponent("out")

        let enhancer = TieredEnhancer(unavailable: [.best: "BestModel needs 12.6 GB; the budget is 11.8 GB"])
        let r = try await optimizeOne(src, into: out, enhancer: enhancer,
                                      Options(quality: .balanced, enhance: .on, upscale: .x4, upscaleTier: .best))
        guard case .failed(let why) = r.status else { return XCTFail("expected a failed item, got \(r.status)") }
        XCTAssertEqual(why, "upscale tier 'best' unavailable: BestModel needs 12.6 GB; the budget is 11.8 GB")
        XCTAssertEqual(enhancer.calls.count, 0, "refused before the enhancer ran — Fast never stood in")
        guard case .none = r.output else { return XCTFail("a refused item delivers nothing") }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertTrue(written.isEmpty, "no file left behind: \(written)")

        // The other tier is untouched by the refusal.
        let fast = try await optimizeOne(src, into: out, enhancer: enhancer,
                                         Options(quality: .balanced, enhance: .on, upscale: .x4, upscaleTier: .fast))
        XCTAssertEqual(fast.recipe.upscaleModel, "FastModel")
    }

    /// An enhancer that predates tiers offers exactly one: Fast runs (and names no model, since none was
    /// reported); Best is refused rather than silently served by the only backer it has.
    func testEnhancerWithoutTiersOffersFastOnly() async throws {
        let legacy = FixedScaleEnhancer(factor: 2)
        let fastVerdict = await legacy.availability(of: .fast)
        let bestVerdict = await legacy.availability(of: .best)
        XCTAssertTrue(fastVerdict.isAvailable)
        XCTAssertFalse(bestVerdict.isAvailable)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(64, 48), to: src)
        let best = try await optimizeOne(src, into: dir.appendingPathComponent("best"), enhancer: legacy,
                                         Options(quality: .balanced, enhance: .on, upscale: .x2, upscaleTier: .best))
        guard case .failed = best.status else { return XCTFail("Best on a one-tier enhancer must fail, got \(best.status)") }

        let fast = try await optimizeOne(src, into: dir.appendingPathComponent("fast"), enhancer: legacy,
                                         Options(quality: .balanced, enhance: .on, upscale: .x2))
        XCTAssertEqual(fast.recipe.upscaled, 2)
        XCTAssertNil(fast.recipe.upscaleTier, "unreported → unknown, never filled from the request")
        XCTAssertNil(fast.recipe.upscaleModel)
    }

    /// Enhance without an upscale asks no tier question: an unavailable Best must not block a restore-only run.
    func testRestoreOnlyRunIgnoresTheTier() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("input.png")
        try writePNG(makeGradientImage(64, 48), to: src)
        let enhancer = TieredEnhancer(unavailable: [.best: "not here"])
        let r = try await optimizeOne(src, into: dir.appendingPathComponent("out"), enhancer: enhancer,
                                      Options(quality: .balanced, enhance: .on, upscale: .none, upscaleTier: .best))
        if case .failed(let why) = r.status { XCTFail("restore-only must not consult the tier: \(why)") }
        XCTAssertEqual(enhancer.calls.count, 1)
        XCTAssertNil(r.recipe.upscaleTier)
        XCTAssertNil(r.recipe.upscaleModel)
    }

    /// Both video call sites carry the backer, gathered from every frame's report.
    func testVideoReceiptNamesTheBackerOnBothProfiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeGradientClip(to: src, w: 64, h: 48, frames: 4)
        let forge = ForgeOptimizer(enhancer: TieredEnhancer(), flowProvider: ZeroFlowProvider())
        let ask = Options(quality: .aggressive, upscale: .x2, upscaleTier: .best)

        for profile in ["native", "web"] {
            let out = dir.appendingPathComponent(profile)
            let stream = profile == "web"
                ? try forge.webOptimize(.url(src), to: .directory(out), ask)
                : try forge.optimize(.url(src), to: .directory(out), ask)
            var result: OptimizeResult?
            for await r in stream { result = r }
            let r = try XCTUnwrap(result, profile)
            XCTAssertEqual(r.recipe.upscaled, 2, profile)
            XCTAssertEqual(r.recipe.upscaleTier, .best, profile)
            XCTAssertEqual(r.recipe.upscaleModel, "BestModel", profile)
        }
    }

    /// Frames that disagree on the backer: the clip keeps no single-model claim.
    func testVideoWhoseFramesRanDifferentModelsClaimsNoSingleBacker() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeGradientClip(to: src, w: 64, h: 48, frames: 4)
        let forge = ForgeOptimizer(enhancer: AlternatingModelEnhancer(), flowProvider: ZeroFlowProvider())
        var result: OptimizeResult?
        for await r in try forge.optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                                          Options(quality: .aggressive, upscale: .x2)) { result = r }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.recipe.upscaleTier, .fast, "every frame reported fast")
        XCTAssertEqual(r.recipe.upscaleModel, "ModelA+ModelB", "two backers ran, so the receipt names both")
    }

    /// A video refused on its tier fails before the SR pipeline starts.
    func testVideoUnavailableTierFailsBeforeAnyFrame() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("clip.mp4")
        try writeGradientClip(to: src, w: 64, h: 48, frames: 4)
        let enhancer = TieredEnhancer(unavailable: [.best: "not registered"])
        let forge = ForgeOptimizer(enhancer: enhancer, flowProvider: ZeroFlowProvider())
        var result: OptimizeResult?
        for await r in try forge.optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                                          Options(quality: .aggressive, upscale: .x2, upscaleTier: .best)) { result = r }
        let r = try XCTUnwrap(result)
        guard case .failed(let why) = r.status else { return XCTFail("expected a failed item, got \(r.status)") }
        XCTAssertEqual(why, "upscale tier 'best' unavailable: not registered")
        XCTAssertEqual(enhancer.calls.count, 0)
    }

    private func optimizeOne(_ src: URL, into out: URL, enhancer: any ImageEnhancer,
                             _ options: Options) async throws -> OptimizeResult {
        var results: [OptimizeResult] = []
        for await r in try ForgeOptimizer(enhancer: enhancer).optimize(.url(src), to: .directory(out), options) {
            results.append(r)
        }
        return try XCTUnwrap(results.first)
    }

    private func parsedReceipt(_ r: OptimizeResult) throws -> [String: Any] {
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(r)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pixelSize(_ url: URL) throws -> (w: Int, h: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ForgeError.decodeFailed(url)
        }
        return (w, h)
    }

    private func makeGradientImage(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorsSpace: cs,
                              colors: [CGColor(red: 0.10, green: 0.20, blue: 0.85, alpha: 1),
                                       CGColor(red: 0.95, green: 0.70, blue: 0.10, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return ctx.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ForgeError.renderFailed("png destination")
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { throw ForgeError.renderFailed("png finalize") }
    }

    private func writeGradientClip(to url: URL, w: Int, h: Int, frames: Int) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
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
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let o = y * rowBytes + x * 4
                    p[o] = UInt8((x * 255 / w + i * 6) % 256)
                    p[o + 1] = UInt8(y * 255 / h)
                    p[o + 2] = UInt8((x + y) * 255 / (w + h))
                    p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        guard writer.status == .completed else {
            throw ForgeError.renderFailed("fixture writer: \(String(describing: writer.error))")
        }
    }
}

/// A model that ignores the requested scale and returns `factor`× pixels — BRIDGE-040's shape
/// (Real-ESRGAN `general` did exactly this, BRIDGE-029). The receipt has to follow the pixels.
struct FixedScaleEnhancer: ImageEnhancer {
    let factor: Int

    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        let w = image.width * factor, h = image.height * factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

/// Two tiers, two named backers, each honouring the scale — and reporting what it ran. `unavailable`
/// is what `availability(of:)` refuses, with its reason; `substitute` makes it run that tier whatever
/// was asked, the misbehaviour a receipt has to expose rather than paper over.
struct TieredEnhancer: ImageEnhancer {
    var unavailable: [UpscaleTier: String] = [:]
    var substitute: UpscaleTier? = nil
    let calls = CallCounter()

    static func model(for tier: UpscaleTier) -> String { tier == .fast ? "FastModel" : "BestModel" }

    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        try await enhanceReporting(image, options: options).image
    }

    func enhanceReporting(_ image: CGImage, options: Options) async throws -> EnhanceOutcome {
        calls.increment()
        let factor: Int = switch options.upscale { case .none: 1; case .x2: 2; case .x4: 4 }
        guard factor > 1 else { return EnhanceOutcome(image: image) }
        let scaled = try await FixedScaleEnhancer(factor: factor).enhance(image, options: options)
        let ran = substitute ?? options.upscaleTier
        return EnhanceOutcome(image: scaled, upscaleTier: ran, upscaleModel: Self.model(for: ran))
    }

    func availability(of tier: UpscaleTier) async -> UpscaleTierAvailability {
        if let why = unavailable[tier] { return .unavailable(tier, model: Self.model(for: tier), reason: why) }
        return .available(tier, model: Self.model(for: tier))
    }
}

/// Reports the fast tier on every frame but alternates the model behind it — a clip that had two backers.
struct AlternatingModelEnhancer: ImageEnhancer {
    let calls = CallCounter()

    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        try await enhanceReporting(image, options: options).image
    }

    func enhanceReporting(_ image: CGImage, options: Options) async throws -> EnhanceOutcome {
        let n = calls.increment()
        let scaled = try await FixedScaleEnhancer(factor: 2).enhance(image, options: options)
        return EnhanceOutcome(image: scaled, upscaleTier: .fast, upscaleModel: n % 2 == 1 ? "ModelA" : "ModelB")
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
