import XCTest
@testable import ForgeOptimizerKit

/// The per-class floor ratchet's pure logic: classification thresholds, the ratchet-up-only rule,
/// `.custom` exemption, and receipt formatting. Calibration provenance: the 9-clip IBM_Pairs
/// balanced-floor sweep (2026-08-09) — the corpus points asserted here are its measured rows.
final class ClassAdaptiveFloorTests: XCTestCase {

    // MARK: - classification (measured corpus points must classify correctly)

    func testGraphicStaticClassifiesFromOvershootAndBPP() {
        // smarter (flat text): overshoot +5.2 at bpp 0.0078 → graphic.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 5.2, bitsPerPixel: 0.0078), .graphic)
    }

    func testTightLandingPhotographicIsGeneralEvenAtLowBPP() {
        // sevilla (people): bpp ≈ 0.0087 sits in graphic territory but the search landed tight
        // (+0.9) — overshoot is the load-bearing signal, bpp only the guard.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 0.9, bitsPerPixel: 0.0087), .general)
    }

    func testHighBPPContentIsGeneralEvenWithOvershoot() {
        // A hypothetical overshooter that still needed real bits (mixed content that happened to
        // clear high) must not be ratcheted — both signals agree or nothing.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 6.0, bitsPerPixel: 0.05), .general)
    }

    func testDenseTextWithMotionLandsGeneral() {
        // is_announce ("dense_text" axis, animated background): +0.1 at bpp 0.0387 — the signals,
        // not the axis label, decide; it behaves like general content.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 0.1, bitsPerPixel: 0.0387), .general)
    }

    // MARK: - HEVC calibration (native-profile sweep 2026-08-09; the guard moves, the rule doesn't)

    func testHEVCTextClassifiesGraphic() {
        // smarter (text) on HEVC: +4.3 @ bpp 0.0061 → graphic.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 4.3, bitsPerPixel: 0.0061, hevc: true),
                       .graphic)
    }

    func testHEVCGuardExcludesWhatTheH264GuardAdmitted() {
        // sevilla on HEVC landed bpp 0.0149 — INSIDE the H.264 guard (0.015) by one
        // ten-thousandth, saved only by overshoot. The HEVC guard (0.009) excludes it outright,
        // so both signals carry margin instead of one doing all the work.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 4.5, bitsPerPixel: 0.0149, hevc: true),
                       .general, "hypothetical high-overshoot sevilla-class must still be general on HEVC")
        // characters4k on HEVC: +3.2 @ 0.0108 — under the overshoot bar AND outside the HEVC guard.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 3.2, bitsPerPixel: 0.0108, hevc: true),
                       .general)
    }

    func testH264ThresholdsUnchangedByTheHEVCSplit() {
        // The H.264 corpus points must classify exactly as before the codec split.
        XCTAssertEqual(ContentClassifier.classify(overshoot: 5.2, bitsPerPixel: 0.0078), .graphic)
        XCTAssertEqual(ContentClassifier.classify(overshoot: 0.9, bitsPerPixel: 0.0087), .general)
    }

    // MARK: - the ratchet rule

    func testRaisedFloorsAreStrictlyAboveTheirPresets() {
        for (preset, floor) in [(QualityTarget.max, 90.0), (.balanced, 80), (.aggressive, 70)] {
            let raised = ContentClassifier.raisedFloor(preset: preset, class: .graphic)
            XCTAssertNotNil(raised)
            XCTAssertGreaterThan(raised!, floor, "ratchet must only ever raise")
        }
    }

    func testGeneralClassNeverRaises() {
        XCTAssertNil(ContentClassifier.raisedFloor(preset: .balanced, class: .general))
    }

    func testCustomFloorsAreExempt() {
        XCTAssertNil(ContentClassifier.raisedFloor(preset: .custom(83.5), class: .graphic),
                     "an explicit floor is an explicit choice — the ratchet keeps its hands off")
    }

    // MARK: - receipt honesty

    func testRecipeShowsRaiseAndClass() {
        var recipe = AppliedRecipe()
        recipe.codec = "H.264"
        recipe.qualityFloor = 90
        recipe.floorRaisedFrom = 80
        recipe.contentClass = "graphic"
        XCTAssertTrue(recipe.description.contains("@SSIMU2≥90 (raised from 80 · graphic)"),
                      "got: \(recipe.description)")
    }

    func testRecipeWithoutRaiseIsUnchanged() {
        var recipe = AppliedRecipe()
        recipe.qualityFloor = 80
        XCTAssertTrue(recipe.description.contains("@SSIMU2≥80"))
        XCTAssertFalse(recipe.description.contains("raised"))
    }
}
