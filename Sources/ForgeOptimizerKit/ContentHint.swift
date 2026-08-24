import Foundation

/// The **planner-hint seam** (PERFORMANCE-BASELINE §6.3) — pre-search content classification.
///
/// The class ratchet (`ContentClassifier`) discovers graphic-static content from the FIRST
/// search's own landing and then pays a SECOND full search at the raised floor — doubling wall
/// time on exactly the content class signage cares most about. A `ContentHintProvider`
/// classifies BEFORE the first search so it can START at the class floor: one classify
/// replaces an entire search.
///
/// Same category-A shape as `ImageEnhancer`/`VideoFlowProvider`: the net-clean Kit defines the
/// contract; the engine-backed implementation (VJEPA2 `contentClassify` — ViT-L clip encoder,
/// [1024] router embedding) injects from ForgeCore/the app. The metallib boundary means the
/// headless CLI never gets a real provider — it keeps the behavioral ratchet as its fallback,
/// and so does any run where the provider returns nil or low confidence.
///
/// Advice, never authority — the LESSONS calibration rule ("the search's landing IS a content
/// classifier; behavior outranks nominal category") is enforced structurally:
/// - a hint may only RAISE the starting floor, only at high confidence
///   (`HintedStartPolicy.minConfidence`), and only through the same
///   `ContentClassifier.raisedFloor` table the ratchet uses — ratchet-up only, `.custom` exempt;
/// - the behavioral signals still audit the landing post-hoc; disagreement files a receipt
///   (`AppliedRecipe.contentHintOutcome`), never a re-run;
/// - a hinted floor the search cannot deliver falls back to the preset-floor search — the
///   stash-and-restore promise mirrored (the stricter attempt runs FIRST here), so a wrong
///   hint can cost one extra attempt, never the deliverable.
public protocol ContentHintProvider: Sendable {
    /// Classify the clip at `url`. Return nil for "no usable hint" (undecodable input, model
    /// unavailable, low-signal content) — the planner then behaves exactly as if no provider
    /// were injected. Non-throwing by design: a hint is advice, and missing advice is not an
    /// error the optimize should surface.
    func classify(_ url: URL) async -> ContentHint?
}

/// What a provider believes about a clip, before any encode has run.
public struct ContentHint: Sendable {
    /// The planner's content-class vocabulary — mirrors `ContentClassifier.ContentClass`.
    public enum ContentClass: String, Sendable {
        /// Flat text / vector / motion-graphics — the fragile class that earns a raised floor.
        case graphic
        /// Everything else. A `general` hint never changes planner behavior — the preset floor
        /// already serves it, and the behavioral ratchet stays armed regardless.
        case general
    }

    public let contentClass: ContentClass
    /// Provider confidence in [0, 1] (clamped). Below `HintedStartPolicy.minConfidence` the
    /// hint is observed (metrics) but changes nothing.
    public let confidence: Double
    /// The provider's own label, carried into receipts verbatim and never interpreted
    /// (VJEPA2's tags are `ssv2_<index>` ids — the embedding head, not the tag, decides).
    public let label: String?

    public init(contentClass: ContentClass, confidence: Double, label: String? = nil) {
        self.contentClass = contentClass
        self.confidence = min(max(confidence, 0), 1)
        self.label = label
    }
}

/// The gate between a hint and the floor it may set. Pure policy — testable without encodes.
enum HintedStartPolicy {
    /// The confidence bar a hint must clear before it may raise the starting floor.
    /// Provisional until the VJEPA2 embedding head is calibrated against encoder behavior
    /// (the receipts this seam files are that calibration's training rows — LESSONS: behavior
    /// outranks the label). The bar sits high because a wrong raise over-spends bytes and, at
    /// worst, costs a fallback search.
    static let minConfidence: Double = 0.9

    /// The floor the FIRST search should start at, or nil to keep the preset floor. Every rule
    /// the behavioral ratchet honors binds here too: graphic-only, high-confidence-only, and
    /// `ContentClassifier.raisedFloor`'s own table (ratchet-up only; `.custom` floors exempt —
    /// an explicit number is an explicit choice).
    static func startingFloor(hint: ContentHint?, preset: QualityTarget) -> Double? {
        guard let hint,
              hint.contentClass == .graphic,
              hint.confidence >= minConfidence,
              let raised = ContentClassifier.raisedFloor(preset: preset, class: .graphic),
              raised > preset.floor
        else { return nil }
        return raised
    }
}

/// Receipt vocabulary for `AppliedRecipe.contentHintOutcome` — what became of an applied hint.
enum HintOutcome: String {
    /// The hinted start delivered AND the landing shows the graphic signature (overshoot + bpp,
    /// the same mechanical signals the ratchet classifies on).
    case confirmed = "raised-confirmed"
    /// The hinted start delivered but the landing did NOT show the graphic signature — the
    /// §6.3 disagreement receipt. The deliverable stands (it cleared a floor at least as strong
    /// as the preset promised); the row recalibrates the hint head.
    case unconfirmed = "raised-unconfirmed"
    /// The landing's behavioral signals could not be read (metadata probe failed) — the raise
    /// stands, honestly unaudited. Distinct from `unconfirmed`: absence of evidence is not
    /// disagreement.
    case unverified = "raised-unverified"
    /// The hinted floor could not deliver; the preset-floor search restored the contract and
    /// its result shipped. The behavioral ratchet is deliberately not re-armed after this —
    /// the raised floor already failed once this item.
    case overreached
}
