import XCTest
import CoreGraphics
@testable import ForgeOptimizerKit

/// AB-T-0195. `conform(.quality)` used to do exactly what `.fast` did — a CoreGraphics resample — while its
/// doc comment promised a model upscale, so a caller asking for quality got interpolation and nothing said so.
/// These lock the replacement: the upscale part runs the requested tier through the enhancer's upscale-only
/// path and the result names what ran; every way it cannot run is a thrown reason, never a quiet `.fast`.
final class ConformQualityTests: XCTestCase {

    private let source = gradient(64, 48)
    private let upscaleToDouble = MediaSpec(size: .fit(maxWidth: 128, maxHeight: 128))   // 64×48 → 128×96

    // MARK: - What runs

    func testQualityUpscaleRunsTheRequestedTierAndNamesTheModel() async throws {
        for tier in [UpscaleTier.fast, .best] {
            let enhancer = UpscaleOnlyEnhancer()
            let r = try await ForgeOptimizer(enhancer: enhancer)
                .conform(source, to: upscaleToDouble, quality: .quality(tier))

            XCTAssertEqual(r.image.width, 128, "\(tier)")
            XCTAssertEqual(r.image.height, 96, "\(tier)")
            XCTAssertEqual(r.quality, .quality(tier))
            XCTAssertEqual(r.upscaleTier, tier, "the tier the enhancer reported running")
            XCTAssertEqual(r.upscaleModel, TieredEnhancer.model(for: tier))
            XCTAssertEqual(r.modelScale, 2)
            XCTAssertEqual(r.description, "upscale×2 [\(tier.rawValue) · \(TieredEnhancer.model(for: tier))] → 128×96")
            XCTAssertEqual(enhancer.upscales.count, 1)
            XCTAssertEqual(enhancer.factors.all, [.x2])
            XCTAssertEqual(enhancer.enhances.count, 0, "a conform never runs the restore-bearing enhance")
        }
    }

    /// The model runs the smallest factor whose output covers the spec in both axes, and its pixels are then
    /// resampled to exactly the spec — including the axis that shrinks and the `.fill` crop.
    func testModelFactorIsTheSmallestThatCoversTheSpecAndTheOutputIsExact() async throws {
        let cases: [(MediaSpec, UpscaleFactor, Int, Int)] = [
            (MediaSpec(size: .fit(maxWidth: 128, maxHeight: 128)), .x2, 128, 96),
            (MediaSpec(size: .exact(width: 65, height: 24)), .x2, 65, 24),      // one axis up, one down
            (MediaSpec(size: .exact(width: 200, height: 100)), .x4, 200, 100),  // 200 > 2 × 64
            (MediaSpec(size: .fill(width: 100, height: 100)), .x4, 100, 100),   // draws 133×100, then crops
        ]
        for (spec, factor, w, h) in cases {
            let enhancer = UpscaleOnlyEnhancer()
            let r = try await ForgeOptimizer(enhancer: enhancer).conform(source, to: spec, quality: .quality(.best))
            XCTAssertEqual(enhancer.factors.all, [factor], "\(spec.size)")
            XCTAssertEqual(r.modelScale, factor.multiplier, "\(spec.size)")
            XCTAssertEqual(r.image.width, w, "\(spec.size)")
            XCTAssertEqual(r.image.height, h, "\(spec.size)")
        }
    }

    /// Only the upscale part of a conform needs a model: a downscale, a same-size conform and a `.fill` whose
    /// draw does not enlarge the source run CoreGraphics under `.quality` too, need no enhancer, and say no
    /// model ran.
    func testConformsThatDoNotEnlargeStayCoreGraphicsAndNameNoModel() async throws {
        let specs = [MediaSpec(size: .fit(maxWidth: 32, maxHeight: 32)),
                     MediaSpec(size: .exact(width: 64, height: 48)),
                     MediaSpec(size: .fill(width: 40, height: 40))]
        let enhancer = UpscaleOnlyEnhancer()
        for spec in specs {
            for forge in [ForgeOptimizer(), ForgeOptimizer(enhancer: enhancer)] {
                let r = try await forge.conform(source, to: spec, quality: .quality(.best))
                let fast = try forge.conform(source, to: spec)
                XCTAssertEqual(r.image.width, fast.width, "\(spec.size)")
                XCTAssertEqual(r.image.height, fast.height, "\(spec.size)")
                XCTAssertNil(r.modelScale, "\(spec.size)")
                XCTAssertNil(r.upscaleTier, "\(spec.size)")
                XCTAssertNil(r.upscaleModel, "\(spec.size)")
                XCTAssertEqual(r.description, "resample → \(fast.width)×\(fast.height)")
            }
        }
        XCTAssertEqual(enhancer.upscales.count + enhancer.enhances.count, 0)
    }

    /// `.fast` is the CoreGraphics resample on every path — the sync call and the async one produce the same
    /// pixels — and never touches an attached enhancer, even for an upscale.
    func testFastIsTheCoreGraphicsResampleAndNeverTouchesTheEnhancer() async throws {
        let enhancer = UpscaleOnlyEnhancer()
        let forge = ForgeOptimizer(enhancer: enhancer)
        let spec = MediaSpec(size: .fit(maxWidth: 256, maxHeight: 256))
        let r = try await forge.conform(source, to: spec, quality: .fast)
        let sync = try forge.conform(source, to: spec)
        XCTAssertEqual(r.image.width, 256)
        XCTAssertEqual(r.image.height, 192)
        XCTAssertEqual(pixels(r.image), pixels(sync), "the async .fast path is the sync resample")
        XCTAssertNil(r.modelScale)
        XCTAssertNil(r.upscaleModel)
        XCTAssertEqual(enhancer.upscales.count + enhancer.enhances.count, 0)
    }

    // MARK: - Every way it cannot run is a thrown reason

    func testQualityUpscaleWithoutAnEnhancerFailsWithTheReason() async {
        await assertRefused(ForgeOptimizer(), .best) { error in
            guard case ForgeError.upscaleTierUnavailable(let tier, let why) = error else { return false }
            return tier == .best && why.contains("no enhancer is attached")
        }
    }

    /// The enhancer's own reason comes back verbatim, and nothing runs — Fast does not stand in for Best.
    func testUnavailableTierFailsWithTheEnhancersReasonAndNothingRuns() async {
        let reason = "RealPLKSR needs 12.6 GB; the engine's memory budget on this Mac is 7.4 GB"
        let enhancer = UpscaleOnlyEnhancer(unavailable: [.best: reason])
        await assertRefused(ForgeOptimizer(enhancer: enhancer), .best) { error in
            guard case ForgeError.upscaleTierUnavailable(let tier, let why) = error else { return false }
            return tier == .best && why == reason
        }
        XCTAssertEqual(enhancer.upscales.count + enhancer.enhances.count, 0)
    }

    /// A whole-clip video tier can never serve a still: refused on every conform, downscales included, even by
    /// an enhancer that would call it available.
    func testLiveActionIsRefusedOnEveryStillConform() async {
        let enhancer = UpscaleOnlyEnhancer()
        for spec in [upscaleToDouble, MediaSpec(size: .fit(maxWidth: 32, maxHeight: 32))] {
            await assertRefused(ForgeOptimizer(enhancer: enhancer), .liveAction, spec: spec) { error in
                guard case ForgeError.upscaleTierUnavailable(let tier, let why) = error else { return false }
                return tier == .liveAction && why == UpscaleTier.liveActionStillReason
            }
        }
        XCTAssertEqual(enhancer.upscales.count, 0)
    }

    /// An enhancer that only offers `enhance` restores before it upscales. The default `upscaleReporting`
    /// refuses rather than serve a conform with it — and its `enhance` is never called.
    func testAnEnhancerWithoutAnUpscaleOnlyPathIsRefusedAndNeverRestores() async {
        let enhancer = RestoreThenUpscaleEnhancer()
        await assertRefused(ForgeOptimizer(enhancer: enhancer), .fast) { error in
            guard case ForgeError.upscaleTierUnavailable(let tier, let why) = error else { return false }
            return tier == .fast && why.contains("no upscale-only path")
        }
        XCTAssertEqual(enhancer.enhances.count, 0)
    }

    /// One model pass is at most ×4. Past that in either axis the conform is refused before any work, with
    /// the way out named (conform in two steps), rather than finished by interpolation.
    func testMoreThanFourTimesIsRefusedBeforeAnyWork() async {
        let enhancer = UpscaleOnlyEnhancer()
        for spec in [MediaSpec(size: .exact(width: 512, height: 384)),     // ×8 both axes
                     MediaSpec(size: .exact(width: 300, height: 48))] {   // ×4.7 in one
            await assertRefused(ForgeOptimizer(enhancer: enhancer), .best, spec: spec) { error in
                guard case ForgeError.invalidOptions(let why) = error else { return false }
                return why.contains("more than ×4") && why.contains("two steps")
            }
        }
        XCTAssertEqual(enhancer.upscales.count, 0)
    }

    /// An enhancer that ran another tier anyway: a conform has no receipt to surface that in, so the call
    /// fails rather than return Fast's pixels under Best's name.
    func testAnEnhancerThatSubstitutesATierIsRefused() async {
        let enhancer = UpscaleOnlyEnhancer(substitute: .fast)
        await assertRefused(ForgeOptimizer(enhancer: enhancer), .best) { error in
            guard case ForgeError.renderFailed(let why) = error else { return false }
            return why.contains("'fast' tier") && why.contains("'best' quality conform")
        }
    }

    /// A model that returned fewer pixels than the spec needs would leave the rest of the upscale to the
    /// resample — interpolation under the model's name. Both shortfalls fail: ×2 for a ×4 request, and no
    /// upscale at all.
    func testAModelThatFallsShortOfTheSpecIsRefused() async {
        let cases: [(Int, MediaSpec)] = [(2, MediaSpec(size: .exact(width: 200, height: 100))),
                                         (1, upscaleToDouble)]
        for (returned, spec) in cases {
            let enhancer = UpscaleOnlyEnhancer(returnFactor: returned)
            await assertRefused(ForgeOptimizer(enhancer: enhancer), .best, spec: spec) { error in
                guard case ForgeError.renderFailed(let why) = error else { return false }
                return why.contains("the rest would be interpolation")
            }
        }
    }

    // MARK: - Helpers

    private func assertRefused(_ forge: ForgeOptimizer, _ tier: UpscaleTier, spec: MediaSpec? = nil,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ matches: (Error) -> Bool) async {
        do {
            let r = try await forge.conform(source, to: spec ?? upscaleToDouble, quality: .quality(tier))
            XCTFail("expected a refusal, got \(r)", file: file, line: line)
        } catch {
            XCTAssertTrue(matches(error), "unexpected error: \(error)", file: file, line: line)
        }
    }

    private func pixels(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}

private func gradient(_ w: Int, _ h: Int) -> CGImage {
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

/// An enhancer with an upscale-only path. It honours the factor (or returns `returnFactor`× instead), reports
/// the tier it ran (`substitute` overrides the one asked), refuses what `unavailable` lists, and counts its
/// restore-bearing `enhance` calls separately — a conform must never make one.
struct UpscaleOnlyEnhancer: ImageEnhancer {
    var unavailable: [UpscaleTier: String] = [:]
    var substitute: UpscaleTier? = nil
    var returnFactor: Int? = nil
    let upscales = CallCounter()
    let enhances = CallCounter()
    let factors = FactorLog()

    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        enhances.increment()
        return image
    }

    func upscaleReporting(_ image: CGImage, factor: UpscaleFactor, tier: UpscaleTier) async throws -> EnhanceOutcome {
        upscales.increment()
        factors.append(factor)
        let scaled = try await FixedScaleEnhancer(factor: returnFactor ?? factor.multiplier)
            .enhance(image, options: Options())
        let ran = substitute ?? tier
        return EnhanceOutcome(image: scaled, upscaleTier: ran, upscaleModel: TieredEnhancer.model(for: ran))
    }

    func availability(of tier: UpscaleTier) async -> UpscaleTierAvailability {
        if let why = unavailable[tier] { return .unavailable(tier, model: TieredEnhancer.model(for: tier), reason: why) }
        return .available(tier, model: TieredEnhancer.model(for: tier))
    }
}

/// An enhancer from before the upscale-only path: `enhance` (restore → upscale) is all it offers.
struct RestoreThenUpscaleEnhancer: ImageEnhancer {
    let enhances = CallCounter()

    func enhance(_ image: CGImage, options: Options) async throws -> CGImage {
        enhances.increment()
        return try await FixedScaleEnhancer(factor: 2).enhance(image, options: options)
    }
}

final class FactorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var factors: [UpscaleFactor] = []
    var all: [UpscaleFactor] { lock.lock(); defer { lock.unlock() }; return factors }
    func append(_ factor: UpscaleFactor) { lock.lock(); defer { lock.unlock() }; factors.append(factor) }
}
