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
    static func classify(overshoot: Double, bitsPerPixel: Double,
                         hevc: Bool = false) -> ContentClass {
        let bppGuard = hevc ? Calibration.maxGraphicBPPHEVC : Calibration.maxGraphicBPP
        return (overshoot >= Calibration.minOvershoot && bitsPerPixel <= bppGuard)
            ? .graphic : .general
    }

    /// The raised floor for a fragile class under a named preset. Returns nil when no raise
    /// applies (general class, already-high floors, or a custom target).
    static func raisedFloor(preset: QualityTarget, class cls: ContentClass) -> Double? {
        guard cls == .graphic else { return nil }
        switch preset {
        case .max:        return Calibration.graphicMaxFloor
        case .balanced:   return Calibration.graphicBalancedFloor
        // Consumer keeps balanced's graphic mapping: a text screenshot deserves the same
        // visually-lossless tier regardless of which ladder entry the camera content rode in on.
        case .consumer:   return Calibration.graphicBalancedFloor
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
        /// HEVC clears at lower bpp across the board (its efficiency shifts the whole scatter),
        /// so the H.264 guard stops guarding: the 2026-08-09 native-profile sweep put general
        /// content at 0.0108 (characters) and 0.0149 (sevilla) — inside the 0.015 H.264 guard,
        /// saved only by their overshoot. 0.009 sits mid-gap between the text exemplar (0.0061)
        /// and the nearest general (0.0108), so BOTH signals carry margin on HEVC. Overshoot
        /// threshold transfers unchanged (text +4.3 vs +3.2 next — thinner than H.264's gap but
        /// on the right side; single-text-exemplar caveat applies to both codecs).
        static let maxGraphicBPPHEVC: Double = 0.009
        static let graphicMaxFloor: Double = 94
        static let graphicBalancedFloor: Double = 90
        static let graphicAggressiveFloor: Double = 82

        /// The camera-noise self-gate (consumer preset, macOS 26+): a conservative temporal
        /// denoise probe scoring BELOW this means the clip demonstrably carries noise, and the
        /// search gates against the DENOISED mezzanine at `cameraDenoisedFloor` — the
        /// research-grounded quality-saturation approach (fidelity-to-noise is not what anyone
        /// is buying). Calibration 2026-08-10: clean production footage probes 95.9–99.5 (the
        /// filter no-ops), genuine handheld grain ~65 — a ~30-point chasm; 90 sits in it with
        /// margin on both sides. Clean content NEVER takes this path: the weaker floor cannot
        /// leak onto content that didn't earn it.
        static let cameraNoiseGate: Double = 90
        static let cameraDenoisedFloor: Double = 70
    }
}
