import XCTest
@testable import ForgeOptimizerKit

/// `Options.contentClass` — the caller stating what the content IS, in lieu of auto-detection,
/// plus the gate that turned auto-detection off.
///
/// Why these exist: the mechanical ratchet shipped for nine months with a miscalibration that no
/// test would have caught, because **nothing asserted what it fires on**. It was gated on
/// 2026-08-16 after measurement (`Tools/hintcal/FINDINGS.md`, AB-L-0053/0054). These tests pin the
/// replacement policy so the next change to it is a deliberate one.
final class DeclaredContentClassTests: XCTestCase {

    // MARK: - The gate

    func testAutoDetectionIsOff() {
        XCTAssertFalse(ContentClassifier.autoDetectEnabled,
                       """
                       Auto-detection is gated OFF deliberately. On a 37-clip signage corpus the \
                       mechanical classifier fired twice, both on blank synthetic test cards, and \
                       never on real signage. Re-enabling needs a signal that separates the \
                       classes — not a new constant. See ContentClassifier.autoDetectEnabled.
                       """)
    }

    /// The gate disables *detection*, not the floor table — an explicit class and the §6.3 hint
    /// seam both still resolve through `raisedFloor`, which is what keeps one floor policy.
    func testGateDoesNotDisableTheFloorTable() {
        XCTAssertEqual(ContentClassifier.raisedFloor(preset: .balanced, class: .graphic), 90)
        XCTAssertEqual(ContentClassifier.raisedFloor(preset: .max, class: .graphic), 94)
        XCTAssertEqual(ContentClassifier.raisedFloor(preset: .aggressive, class: .graphic), 82)
    }

    // MARK: - Declared class → starting floor

    func testDeclaredGraphicResolvesToTheClassFloor() {
        for (preset, expected) in [(QualityTarget.balanced, 90.0), (.max, 94.0),
                                   (.consumer, 90.0), (.aggressive, 82.0)] {
            XCTAssertEqual(ContentClassifier.raisedFloor(preset: preset, class: .graphic), expected,
                           "declared graphic under \(preset) should start at \(expected)")
        }
    }

    /// `.general` is "no raise", not "a different raise" — the preset floor already serves it.
    func testDeclaredGeneralNeverRaises() {
        for preset in [QualityTarget.balanced, .max, .consumer, .aggressive] {
            XCTAssertNil(ContentClassifier.raisedFloor(preset: preset, class: .general))
        }
    }

    /// An explicit number is an explicit choice; a class must never move it.
    func testCustomTargetIsExemptFromDeclaredClass() {
        XCTAssertNil(ContentClassifier.raisedFloor(preset: .custom(75), class: .graphic))
        XCTAssertNil(ContentClassifier.raisedFloor(preset: .custom(95), class: .graphic))
    }

    /// Ratchet-UP only: a class may strengthen the promise, never weaken it. `.aggressive` (70)
    /// rises to 82; nothing resolves BELOW its preset floor.
    func testClassFloorNeverLandsBelowThePresetFloor() {
        for preset in [QualityTarget.balanced, .max, .consumer, .aggressive] {
            guard let raised = ContentClassifier.raisedFloor(preset: preset, class: .graphic) else { continue }
            XCTAssertGreaterThan(raised, preset.floor,
                                 "\(preset): a class floor at or below the preset is not a raise")
        }
    }

    // MARK: - Options plumbing

    func testOptionsDefaultsToNoDeclaredClass() {
        XCTAssertNil(Options().contentClass,
                     "nil means 'no opinion' — nothing infers a class on the caller's behalf")
    }

    func testOptionsCarriesTheDeclaredClass() {
        XCTAssertEqual(Options(contentClass: .graphic).contentClass, .graphic)
        XCTAssertEqual(Options(quality: .max, contentClass: .general).contentClass, .general)
    }

    /// The vocabulary must stay in step with `ContentHint.ContentClass`, since both resolve
    /// through the same floor table and a drift between them would silently split the policy.
    func testClassVocabularyMatchesTheHintSeam() {
        XCTAssertEqual(Set(ContentClassifier.ContentClass.allCases.map(\.rawValue)),
                       ["graphic", "general"])
        XCTAssertEqual(ContentHint.ContentClass.graphic.rawValue,
                       ContentClassifier.ContentClass.graphic.rawValue)
        XCTAssertEqual(ContentHint.ContentClass.general.rawValue,
                       ContentClassifier.ContentClass.general.rawValue)
    }
}
