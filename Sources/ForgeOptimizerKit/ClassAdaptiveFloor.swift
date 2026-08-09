import Foundation

/// The per-class floor ratchet — planner policy, deliberately NOT in media-bridge (whose
/// `targetScore` stays an explicit contract; the Kit is where floors get chosen).
///
/// Why it exists: "equal perceived quality" maps to different SSIMULACRA2 floors per content
/// class. Measured on the IBM Vimeo pairs (2026-08-09): Vimeo's own per-title operating point
/// spans p10 **77 (extreme motion) → 94 (flat text)** — text/graphic content is exactly where
/// encode artifacts glare on signage, and a single global floor ships worse-than-Vimeo text
/// while over-spending on motion. The ratchet raises the floor for fragile classes.
///
/// Two hard rules:
/// - **Ratchet UP only.** The preset's floor is a promise; content class may strengthen it,
///   never weaken it. Motion content keeps the preset floor even though Vimeo dips below it.
/// - **`.custom` floors are exempt.** An explicit number is an explicit choice.
///
/// The classifier is mechanical — no model, no probe pass: the signals fall out of the search
/// that already ran (the first, preset-floor encode).
enum ContentClassifier {

    enum ContentClass: String {
        /// Flat text / vector / motion-graphics — clears floors with huge overshoot at tiny
        /// bitrates, and the class where artifacts are most visible. Gets the raised floor.
        case graphic
        /// Everything else (photographic / motion / mixed) — keeps the preset floor.
        case general
    }

    /// Classify from the preset-floor search result.
    /// - `overshoot`: achieved p10 minus the floor asked for. Graphic-static content blows past
    ///   the floor (the descent extension firing is the same signature); photographic content
    ///   lands tight because the search descends until the floor pushes back.
    /// - `bitsPerPixel`: emitted bits / (w·h·fps·duration) — graphic content clears at an order
    ///   of magnitude fewer bpp than photographic.
    /// Thresholds calibrated on the 9-clip IBM_Pairs balanced-floor sweep (2026-08-09) — see
    /// `classcal.csv` provenance in the session notes; both signals must agree (AND, not OR) so
    /// a tight-landing low-bpp photographic clip is never misclassified.
    static func classify(overshoot: Double, bitsPerPixel: Double) -> ContentClass {
        (overshoot >= Calibration.minOvershoot && bitsPerPixel <= Calibration.maxGraphicBPP)
            ? .graphic : .general
    }

    /// The raised floor for a fragile class under a named preset. Returns nil when no raise
    /// applies (general class, already-high floors, or a custom target).
    static func raisedFloor(preset: QualityTarget, class cls: ContentClass) -> Double? {
        guard cls == .graphic else { return nil }
        switch preset {
        case .max:        return Calibration.graphicMaxFloor
        case .balanced:   return Calibration.graphicBalancedFloor
        case .aggressive: return Calibration.graphicAggressiveFloor
        case .custom:     return nil
        }
    }

    /// Calibration constants — measured, not designed. Provenance: IBM_Pairs balanced-floor
    /// sweep 2026-08-09 (9 clips across text/structure/gradient/3d/characters/people/motion
    /// axes). The measured scatter: graphic-static (smarter) overshoot +5.2 @ bpp 0.0078;
    /// everything general landed within +0.9 of the floor — EXCEPT that photographic people
    /// content (sevilla) shares the LOW-bpp region (0.0087), which is why overshoot is the
    /// load-bearing signal and bpp only the guard, and why the rule is AND, not OR. "Dense
    /// text" with animated backing (is_announce, +0.1 @ 0.0387) correctly stays general —
    /// the signals outrank the axis label.
    enum Calibration {
        static let minOvershoot: Double = 4
        static let maxGraphicBPP: Double = 0.015
        static let graphicMaxFloor: Double = 94
        static let graphicBalancedFloor: Double = 90
        static let graphicAggressiveFloor: Double = 82
    }
}
