import XCTest
import AVFoundation
import CoreVideo
@testable import ForgeOptimizerKit

/// The §6.3 planner-hint seam. Three layers under test:
/// 1. `HintedStartPolicy` — the pure gate between a hint and the floor it may set (no encodes);
/// 2. receipt formatting — hinted raises, disagreement, and over-reach must read honestly, and
///    the behavioral ratchet's existing receipt must not grow hint language;
/// 3. the integration contract on a real (synthetic) clip — a NON-actionable hint changes
///    NOTHING (the behavioral ratchet stays the fallback, receipts identical to no-provider),
///    and a high-confidence graphic hint starts at the class floor without the ratchet's
///    second search.
final class ContentHintTests: XCTestCase {

    // MARK: - HintedStartPolicy (pure)

    func testHighConfidenceGraphicRaisesStartToClassFloor() {
        let hint = ContentHint(contentClass: .graphic, confidence: 0.97)
        XCTAssertEqual(HintedStartPolicy.startingFloor(hint: hint, preset: .balanced), 90)
        XCTAssertEqual(HintedStartPolicy.startingFloor(hint: hint, preset: .max), 94)
        XCTAssertEqual(HintedStartPolicy.startingFloor(hint: hint, preset: .aggressive), 82)
    }

    func testConsumerPresetKeepsBalancedGraphicMapping() {
        let hint = ContentHint(contentClass: .graphic, confidence: 1)
        XCTAssertEqual(HintedStartPolicy.startingFloor(hint: hint, preset: .consumer), 90,
                       "a text screenshot deserves the visually-lossless tier on the consumer rung too")
    }

    func testLowConfidenceNeverRaises() {
        let hint = ContentHint(contentClass: .graphic, confidence: 0.89)
        XCTAssertNil(HintedStartPolicy.startingFloor(hint: hint, preset: .balanced))
    }

    func testThresholdIsInclusive() {
        let hint = ContentHint(contentClass: .graphic,
                               confidence: HintedStartPolicy.minConfidence)
        XCTAssertNotNil(HintedStartPolicy.startingFloor(hint: hint, preset: .balanced))
    }

    func testGeneralHintNeverRaises() {
        let hint = ContentHint(contentClass: .general, confidence: 1)
        XCTAssertNil(HintedStartPolicy.startingFloor(hint: hint, preset: .balanced))
    }

    func testCustomFloorsAreExemptFromHints() {
        let hint = ContentHint(contentClass: .graphic, confidence: 1)
        XCTAssertNil(HintedStartPolicy.startingFloor(hint: hint, preset: .custom(83.5)),
                     "an explicit floor is an explicit choice — hints keep their hands off too")
    }

    func testNilHintNeverRaises() {
        XCTAssertNil(HintedStartPolicy.startingFloor(hint: nil, preset: .balanced))
    }

    func testConfidenceClamps() {
        XCTAssertEqual(ContentHint(contentClass: .graphic, confidence: 1.7).confidence, 1)
        XCTAssertEqual(ContentHint(contentClass: .graphic, confidence: -0.2).confidence, 0)
    }

    // MARK: - receipt honesty

    func testHintedRaiseReadsHinted() {
        var recipe = AppliedRecipe()
        recipe.codec = "H.264"
        recipe.qualityFloor = 90
        recipe.floorRaisedFrom = 80
        recipe.contentClass = "graphic"
        recipe.contentHintClass = "graphic"
        recipe.contentHintConfidence = 0.97
        recipe.contentHintOutcome = HintOutcome.confirmed.rawValue
        XCTAssertTrue(recipe.description.contains("@SSIMU2≥90 (raised from 80 · graphic · hinted)"),
                      "got: \(recipe.description)")
    }

    func testDisagreementReceiptSaysSo() {
        var recipe = AppliedRecipe()
        recipe.qualityFloor = 90
        recipe.floorRaisedFrom = 80
        recipe.contentClass = "graphic"
        recipe.contentHintClass = "graphic"
        recipe.contentHintOutcome = HintOutcome.unconfirmed.rawValue
        XCTAssertTrue(recipe.description.contains("hinted, behavior disagreed"),
                      "the §6.3 disagreement receipt must be legible: \(recipe.description)")
    }

    func testOverreachReceiptKeepsThePresetFloorVisible() {
        var recipe = AppliedRecipe()
        recipe.qualityFloor = 80
        recipe.contentHintClass = "graphic"
        recipe.contentHintOutcome = HintOutcome.overreached.rawValue
        XCTAssertTrue(recipe.description.contains("@SSIMU2≥80"), "got: \(recipe.description)")
        XCTAssertTrue(recipe.description.contains("hint overreached"), "got: \(recipe.description)")
        XCTAssertFalse(recipe.description.contains("raised"),
                       "an over-reach did NOT raise the floor — the receipt must not claim one")
    }

    func testBehavioralRaiseFormattingUnchanged() {
        // The ratchet's own receipt (no hint fields) is pinned by ClassAdaptiveFloorTests; this
        // guards the other direction — no hint language may leak into it.
        var recipe = AppliedRecipe()
        recipe.qualityFloor = 90
        recipe.floorRaisedFrom = 80
        recipe.contentClass = "graphic"
        XCTAssertTrue(recipe.description.contains("(raised from 80 · graphic)"),
                      "got: \(recipe.description)")
        XCTAssertFalse(recipe.description.contains("hint"))
    }

    // MARK: - integration: fallback + the hinted single search

    private struct FixedHint: ContentHintProvider {
        let hint: ContentHint?
        func classify(_ url: URL) async -> ContentHint? { hint }
    }

    /// Progress-detail collector (the narration is how the test observes WHICH searches ran).
    private final class DetailLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    /// Non-actionable hints (no provider / provider returns nil / below-threshold confidence)
    /// must leave the planner EXACTLY as it was: identical floors, identical raise decision,
    /// identical status — and no hint receipt fields. This is the fallback path's contract:
    /// the behavioral ratchet, untouched.
    func testNonActionableHintsChangeNothing() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("flat.mov")
        try makeFlatGraphicClip(at: src, w: 1280, h: 720, frames: 48)

        let arms: [(String, (any ContentHintProvider)?)] = [
            ("no-provider", nil),
            ("nil-hint", FixedHint(hint: nil)),
            ("low-confidence", FixedHint(hint: ContentHint(contentClass: .graphic, confidence: 0.5))),
        ]
        var receipts: [(String, AppliedRecipe, String)] = []
        for (name, provider) in arms {
            let forge = ForgeOptimizer(hintProvider: provider)
            var results: [OptimizeResult] = []
            for await r in try forge.webOptimize(.url(src),
                                                 to: .directory(tmp.appendingPathComponent(name))) {
                results.append(r)
            }
            let r = try XCTUnwrap(results.first, "\(name): no result")
            receipts.append((name, r.recipe, String(describing: r.status)))
        }

        let (refName, refRecipe, refStatus) = receipts[0]
        for (name, recipe, status) in receipts {
            XCTAssertEqual(recipe.qualityFloor, refRecipe.qualityFloor,
                           "\(name) diverged from \(refName) on the effective floor")
            XCTAssertEqual(recipe.floorRaisedFrom, refRecipe.floorRaisedFrom,
                           "\(name) diverged from \(refName) on the raise decision")
            XCTAssertEqual(recipe.contentClass, refRecipe.contentClass,
                           "\(name) diverged from \(refName) on the content class")
            XCTAssertEqual(status, refStatus, "\(name) diverged from \(refName) on status")
            XCTAssertNil(recipe.contentHintClass,
                         "\(name): a hint that changed nothing must not leave a receipt")
            XCTAssertNil(recipe.contentHintOutcome, "\(name)")
        }
    }

    /// The §6.3 win: a high-confidence graphic hint starts the search AT the class floor —
    /// the receipt shows the raise, the hint outcome rides along, and the ratchet's second
    /// search never runs (its narration line is the observable).
    func testHighConfidenceGraphicHintSkipsTheSecondSearch() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("flat.mov")
        try makeFlatGraphicClip(at: src, w: 1280, h: 720, frames: 48)

        let forge = ForgeOptimizer(
            hintProvider: FixedHint(hint: ContentHint(contentClass: .graphic, confidence: 0.97,
                                                      label: "test")))
        let log = DetailLog()
        var results: [OptimizeResult] = []
        for await r in try forge.webOptimize(.url(src), to: .directory(tmp.appendingPathComponent("o")),
                                             Options(),
                                             progress: { p in if let d = p.detail { log.add(d) } }) {
            results.append(r)
        }
        let r = try XCTUnwrap(results.first)

        guard case .optimized = r.status else {
            return XCTFail("expected delivery on a flat clip with a fat source, got \(r.status) — "
                           + "recipe: \(r.recipe), narration: \(log.all)")
        }
        XCTAssertEqual(r.recipe.qualityFloor, 90, "the hinted start IS the class floor")
        XCTAssertEqual(r.recipe.floorRaisedFrom, 80)
        XCTAssertEqual(r.recipe.contentClass, "graphic")
        XCTAssertEqual(r.recipe.contentHintClass, "graphic")
        XCTAssertEqual(r.recipe.contentHintConfidence, 0.97)
        let outcome = try XCTUnwrap(r.recipe.contentHintOutcome)
        XCTAssertTrue(outcome.hasPrefix("raised-"),
                      "a delivered hinted start must record a raised-* outcome, got \(outcome)")

        let narration = log.all
        XCTAssertTrue(narration.contains("content hint: graphic"),
                      "the hinted start must be narrated: \(narration)")
        XCTAssertFalse(narration.contains("Graphic content detected"),
                       "the ratchet's second search must not run on a hinted start: \(narration)")
    }

    // MARK: - fixtures

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-hint-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A graphic-STATIC clip in the ratchet's sense: charcoal ground + solid text-like bars,
    /// identical on every frame — written as a ProRes .mov MASTER. ProRes matters twice: it is
    /// what real signage masters look like (fat mezzanine → the web verb takes the conversion
    /// path, where floors decide and the size gate can't starve the test), and an H.264 source
    /// would be self-defeating — the writer's rate control refuses to spend bits on flat
    /// content, producing a source already leaner than a floor-90 encode (measured here first:
    /// the "synthetic proxies fail in both directions" lesson, video edition).
    private func makeFlatGraphicClip(at url: URL, w: Int, h: Int, frames: Int) throws {
        let fps = 24
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)

        // Render the (static) frame pattern once; memcpy it into each frame's buffer.
        var pattern = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let inBar = (y > h / 6 && y < h / 6 + 24 && x > w / 10 && x < w * 7 / 10)
                    || (y > h / 2 && y < h / 2 + 40 && x > w / 10 && x < w / 2)
                    || (y > h * 3 / 4 && y < h * 3 / 4 + 12 && x > w / 10 && x < w * 9 / 10)
                let o = (y * w + x) * 4
                pattern[o] = inBar ? 240 : 24
                pattern[o + 1] = inBar ? 235 : 22
                pattern[o + 2] = inBar ? 230 : 20
                pattern[o + 3] = 255
            }
        }

        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                pattern.withUnsafeBytes { srcRaw in
                    let src = srcRaw.baseAddress!
                    for y in 0..<h {
                        memcpy(base + y * rowBytes, src + y * w * 4, w * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i),
                                                             timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
    }
}
