import XCTest
@testable import ForgeOptimizerKit

/// The consumer-web preset: a DISTINCT documented promise (floor 75 + the 1080p rung by
/// default + the graphic ratchet still armed) — research-grounded in CONSUMER-PLAYBOOK §6.
/// Never a silent weakening of `balanced`.
final class ConsumerPresetTests: XCTestCase {

    func testConsumerShape() {
        XCTAssertEqual(QualityTarget.consumer.floor, 75)
        XCTAssertEqual(QualityTarget.consumer.impliedMaxHeight, 1080,
                       "consumer implies the 1080p rung — every platform's default viewing rung")
    }

    func testOnlyConsumerImpliesARung() {
        XCTAssertNil(QualityTarget.max.impliedMaxHeight)
        XCTAssertNil(QualityTarget.balanced.impliedMaxHeight)
        XCTAssertNil(QualityTarget.aggressive.impliedMaxHeight)
        XCTAssertNil(QualityTarget.custom(75).impliedMaxHeight,
                     "an explicit floor is an explicit choice — no implied resolution either")
    }

    func testExplicitResolutionOverridesImpliedRung() {
        // The Kit resolves options.resolution.maxHeight ?? quality.impliedMaxHeight — an explicit
        // choice always wins. Pin the resolution half of that here.
        let opts = Options(quality: .consumer, resolution: .maxHeight(720))
        XCTAssertEqual(opts.resolution.maxHeight ?? opts.quality.impliedMaxHeight, 720)
        let defaulted = Options(quality: .consumer)
        XCTAssertEqual(defaulted.resolution.maxHeight ?? defaulted.quality.impliedMaxHeight, 1080)
    }

    func testConsumerIsInTheStandardLadder() {
        XCTAssertTrue(Preset.standard.contains { $0.id == "consumer" })
        let p = Preset.standard.first { $0.id == "consumer" }!
        XCTAssertEqual(p.floor, 75)
        // Ladder stays highest-floor-first.
        let floors = Preset.standard.map(\.floor)
        XCTAssertEqual(floors, floors.sorted(by: >), "ladder order is highest-floor first")
    }

    func testGraphicContentStillRatchetsUnderConsumer() {
        XCTAssertEqual(ContentClassifier.raisedFloor(preset: .consumer, class: .graphic), 90,
                       "a text screenshot deserves the visually-lossless tier under any ladder entry")
        XCTAssertNil(ContentClassifier.raisedFloor(preset: .consumer, class: .general))
    }
}
