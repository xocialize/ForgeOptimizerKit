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
public enum ContentClassifier {

    /// Whether the MECHANICAL classifier may raise a floor on its own.
    ///
    /// 🚨 **OFF since 2026-08-16 — gated, not tuned.** Measured across 70 receipts from three
    /// corpora with frames inspected for ground truth (`Tools/hintcal/FINDINGS.md`, AB-L-0053,
    /// AB-L-0054):
    ///
    /// - On a 37-clip purpose-built signage corpus it fired **twice, both on blank synthetic test
    ///   cards** (solid field + a frame counter). Zero raises on real signage.
    /// - `overshoot` — the documented load-bearing signal — ranks blank test cards ABOVE flat-vector
    ///   signage ABOVE dense-text signage, i.e. the **inverse** of artifact visibility. It only
    ///   appears when the search hits its descent limit, so it measures search behaviour, not
    ///   content, and goes quiet exactly where a raise is most warranted.
    /// - `bpp` cannot stand in: graphic content spans **0.0053–0.0866** (16×) across labelled
    ///   receipts; the 0.009 guard catches 7 of 27 graphic clips.
    /// - The AND rule's founding counter-example is mislabelled — `AISC_Sevilla_players_V02` is
    ///   described below as "photographic people content", but eight frames across its full 69 s are
    ///   flat vector illustration. Its low bpp was correct, and the rule was built to exclude it.
    ///
    /// ⚠️ Re-enabling is a visible edit to this file, and it needs a signal that separates the
    /// classes — not a new constant. The calibration constants below are LEFT AS MEASURED so the
    /// 2026-08-09 provenance stays readable; they are simply no longer consulted automatically.
    ///
    /// Callers wanting a class floor today pass one explicitly (`Options.contentClass`), which is
    /// authoritative and skips detection entirely.
    public static let autoDetectEnabled = false

    public enum ContentClass: String, Sendable, CaseIterable {
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
    ///
    /// 🚨 **NOT CONSULTED while `autoDetectEnabled == false`.** Both premises above were measured
    /// false on 2026-08-16 — see `autoDetectEnabled`. Retained unchanged so the original provenance
    /// stays legible next to the evidence that overturned it.
    static func classify(overshoot: Double, bitsPerPixel: Double,
                         hevc: Bool = false) -> ContentClass {
        let bppGuard = hevc ? Calibration.maxGraphicBPPHEVC : Calibration.maxGraphicBPP
        return (overshoot >= Calibration.minOvershoot && bitsPerPixel <= bppGuard)
            ? .graphic : .general
    }

    /// The raised floor for a fragile class under a named preset. Returns nil when no raise
    /// applies (general class, already-high floors, or a custom target).
    ///
    /// Deliberately NOT gated by `autoDetectEnabled`: the gate disables *detection*, not the
    /// preset→floor table. An explicitly supplied class (`Options.contentClass`) and the §6.3 hint
    /// seam both still resolve through here, which is what keeps them on one floor policy.
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
    }
}
