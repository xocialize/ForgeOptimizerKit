import Foundation
import UniformTypeIdentifiers

// The ForgeOptimizer I/O contract (PRD §4). Three verbs — analyze / optimize / conform — share this
// vocabulary. Everything here is value-typed + Sendable so it crosses the AsyncStream / actor seam.

// MARK: - Input

public enum Source: Sendable {
    case url(URL)
    case urls([URL])

    public var urls: [URL] {
        switch self {
        case .url(let u): return [u]
        case .urls(let a): return a
        }
    }
}

/// Where an `optimize` output goes. Read-only `analyze` ignores it; `conform` returns in memory.
public enum Destination: Sendable {
    case directory(URL)             // write `<stem>.<ext>` into this folder (created if missing)
    case alongside(suffix: String)  // write next to the input, filename + suffix
    /// Write EXACTLY here (host-dictated; parent created) — the pipeline path.
    ///
    /// The extension on this URL is **advisory**: Forge does not derive the container from it.
    /// `optimize` writes HEIC bytes for stills and HEVC-in-mp4 for video whatever the path says
    /// (`.fileURL("out.jpg")` receives HEIC; `.fileURL("clip.webm")` receives mp4) — read the real
    /// container back from `OptimizeResult.outputType` and name the deliverable from that.
    ///
    /// ⚠️ **One exception: on `webOptimize`, a `.png`/`.jpg`/`.jpeg` extension PINS that still
    /// format**, exactly as an explicit `Options.output` would (a `.jpg` pin on real transparency
    /// is refused, same as the option). That is deliberate, but it has a trap — a host that
    /// mirrors the source extension onto its temp path silently benches the PNG↔JPEG race for
    /// every PNG source, and the receipt looks like an ordinary PNG win because it IS one; it
    /// just never had a competitor. Pass an **extension-less** path when you want the race to
    /// decide. An explicit `Options.output` that contradicts a `.png`/`.jpg` host path is refused
    /// on both profiles.
    case fileURL(URL)
    case inMemory                   // return bytes in the receipt, write nothing
}

// MARK: - Options

/// The perceptual floor an `optimize` must clear — an SSIMULACRA2 score in [0, 100], anchored to the
/// metric authors' MOS scale (cloudinary/ssimulacra2): 70 = high ("artifacts perceptible, but not
/// annoying" — the `cjxl -d 2.5` distribution standard) · 80 = very high (not noticeable side-by-side)
/// · 85 = excellent (not noticeable in-place) · 90 = visually lossless (not noticeable in a flicker
/// test). The ladder is deliberately *spread* across that range so the tiers actually differentiate —
/// the old clustered 90/85/80 all sat in "indistinguishable" territory (no room to compress).
/// NB: brand-sensitive signage may warrant a higher-floor profile (see Corpus/README re-baseline).
public enum QualityTarget: Sendable {
    case max          // ≥ 90 — visually lossless (hero / archival)
    case balanced     // ≥ 80 — very high, not noticeable side-by-side (default)
    /// ≥ 75 + the 1080p ladder rung by default — the CONSUMER web semantic, research-grounded
    /// (CONSUMER-PLAYBOOK §6): consumer viewing is a no-reference condition (the SSIMULACRA2
    /// author anchor at 70 = "without reference, an average observer does not notice artifacts");
    /// measured consumer-platform practice spans p10 ~75–85 with grain rungs below 70; and p10
    /// aggregation makes 75 stricter than it sounds — the WORST DECILE of frames sits at "high".
    /// This is a distinct documented promise, not a weakening of `balanced`: graphic content
    /// still ratchets UP (text → 90) under it.
    case consumer
    case aggressive   // ≥ 70 — high; the standard distribution target (smallest acceptable)
    case custom(Double)

    public var floor: Double {
        switch self {
        case .max: return 90
        case .balanced: return 80
        case .consumer: return 75
        case .aggressive: return 70
        case .custom(let v): return v
        }
    }

    /// The default resolution class this target implies when the caller didn't choose one.
    /// Only `.consumer` implies a rung (1080p — every consumer platform's default viewing rung;
    /// it also collapses the camera-grain cost curve, the preset's whole point). Others: nil =
    /// keep the source resolution unless the caller says otherwise.
    public var impliedMaxHeight: Int? {
        if case .consumer = self { return 1080 }
        return nil
    }
}

/// Whether the CONSUMER preset's camera-noise self-gate may run.
///
/// `.auto` (the default) is the shipped behaviour: under `.consumer`, a cheap temporal-denoise
/// probe decides whether the clip carries real sensor noise, and demonstrably noisy content is
/// then scored against a DENOISED reference at the camera floor instead of the preset floor.
/// `.off` skips the probe outright and keeps the preset's own floor and reference.
///
/// Reach for `.off` when you already know the content is **rendered, never captured** — signage,
/// slides, motion graphics, screen recordings. The gate is the planner's one floor-LOWERING
/// device, and on rendered content a denoised reference softens exactly the text edges the
/// content exists to show. Declaring `Options.contentClass = .graphic` suppresses it too, and
/// says more; this knob is for hosts that want the policy without making a claim about content.
public enum CameraGate: Sendable { case auto, off }

public enum EnhancePolicy: Sendable { case off, auto, on }   // Phase A honors only `.off`
public enum UpscaleFactor: Sendable { case none, x2, x4 }    // Phase B (engine / Real-ESRGAN)

/// The deliverable format. `.auto` = the verb's opinionated default (optimize: HEIC stills /
/// HEVC video; webOptimize: PNG↔JPEG race / H.264 video). An explicit still format
/// (`.heic`/`.jpeg`/`.png`) pins the stills encode with **conversion semantics**: it delivers even
/// when larger than the source, because the caller asked for the format, not for a size win
/// (pinning the format the source already has keeps the honest-skip size gate). `.hevc` names the
/// native video default and is video-only. Invalid pairings — a still format on video, `.hevc` on
/// a still, `.heic` under `webOptimize`, a pin that contradicts a host-pinned `.fileURL`
/// extension, `.jpeg` on an image with real transparency, any still pin on an animated GIF headed
/// to web video — fail the item honestly rather than silently reinterpreting the request.
public enum OutputFormat: Sendable { case auto, heic, jpeg, png, hevc }

/// How hard `analyze` verifies file integrity. `.structural` (the default) runs millisecond byte
/// walks — box chains, PNG CRCs, JPEG EOI, EBML sizes — safe on every ingest; `.deep` adds a full
/// decode-to-EOF pass (costs a decode of the whole file) for incident triage and must-validate
/// ingests. `optimize` ignores this: its encode is already a full decode.
public enum IntegrityLevel: Sendable { case structural, deep }

/// Resolution stepping for `optimize` (video). `.source` keeps native resolution (same-res target-quality);
/// `.maxHeight` steps down to ≤ that resolution CLASS — it caps the SHORT side, so a 1080×1920
/// portrait phone clip IS 1080p and stays untouched (media-bridge 0.24.0 semantics), aspect
/// preserved, never upscaling — the SR/upscale
/// direction is the enhance path. Quality is measured at the *target* resolution.
public enum ResolutionTarget: Sendable {
    case source
    case maxHeight(Int)   // e.g. .maxHeight(1080) = ≤ 1080p, .maxHeight(720) = ≤ 720p

    public var maxHeight: Int? { if case .maxHeight(let h) = self { return h }; return nil }
}

public struct Options: Sendable {
    public var quality: QualityTarget
    public var resolution: ResolutionTarget
    public var enhance: EnhancePolicy
    public var upscale: UpscaleFactor
    public var output: OutputFormat
    /// Shed carried metadata (EXIF/GPS/IPTC/XMP…) from the deliverable. `false` (default)
    /// preserves: a still carries the source's metadata over losslessly; the video remux
    /// fast-path passes it through. (Video *re-encodes* don't carry source metadata yet — the
    /// writer is metadata-clean by construction; preserving there is a media-bridge follow-up.)
    /// `true` guarantees a metadata-clean deliverable on every path — including the remux, which
    /// gets scrubbed — and forces delivery when the source carries metadata even if the re-encode
    /// isn't smaller: an honest skip would keep the original, and the original's metadata is
    /// exactly what the caller asked to shed. Two things are never treated as metadata: ICC color
    /// profiles (the pixels' rendering contract) and orientation, which is baked into pixels at
    /// decode so outputs render upright in both modes. The one path the guarantee cannot reach is
    /// a REFUSAL: an alpha video `optimize` declines keeps the original, metadata included, and
    /// the receipt's `strippedMetadata` stays false — the skip reason says why nothing shipped.
    public var stripMetadata: Bool
    /// `analyze`-only: integrity verification tier (see `IntegrityLevel`).
    public var integrity: IntegrityLevel

    /// **Caller-supplied content class, in lieu of auto-detection.**
    ///
    /// When set, it resolves through the same `ContentClassifier.raisedFloor` table the ratchet used
    /// — so `.graphic` starts the FIRST search at the class floor (balanced 80 → 90) and `.general`
    /// keeps the preset. One search either way; there is no second pass and no confidence gate,
    /// because an explicit class is a statement, not an estimate.
    ///
    /// `nil` (the default) means "no opinion": the preset floor applies. Auto-detection is gated off
    /// (`ContentClassifier.autoDetectEnabled`), so nothing infers a class on your behalf.
    ///
    /// ⚠️ `.custom` quality targets are exempt — an explicit floor already is an explicit choice,
    /// and a class must never move a number the caller stated outright.
    public var contentClass: ContentClassifier.ContentClass?

    /// Whether the `.consumer` preset's camera-noise self-gate may run (see `CameraGate`).
    /// `.auto` by default; no effect under any other preset, which never run the probe.
    public var cameraGate: CameraGate

    /// **A second, weaker-floor rendition beside the primary — taken from the search that already
    /// ran, not from a second one.** `nil` (the default) changes nothing.
    ///
    /// `optimize` on video encodes and scores a whole ladder of candidates on its way to the floor
    /// and deletes every one it does not ship. Ask for a `secondary` and the smallest of those that
    /// cleared its floor is delivered to `secondary.output` instead of being swept — a complete
    /// file, same codec/container/resolution, audio muxed in, for no additional encode time.
    ///
    /// The intended use is a delivery rung for constrained playback (the bad-uplink venue), chosen
    /// per destination beside the primary, where the alternative is either shipping nothing or
    /// paying a second full search.
    ///
    /// ⚠️ **It is a harvest, not a search.** What lands is whichever bitrate the primary's bisection
    /// happened to try that cleared `floor` — the smallest such, but drawn from a ladder built for a
    /// different floor. A dedicated `optimize` at `floor` will generally produce a smaller file.
    /// `SecondaryResult.provenance` says exactly this, and it belongs in any ledger that records the
    /// rendition, so the choice to take the free one stays a visible choice.
    ///
    /// **Video only** — and only the ordinary `optimize` route. Stills clear their floors at a few
    /// MB and have no uplink problem, and the conversion routes (animated GIF → web mp4, the
    /// upscale → web deliverable) already encode toward a different contract. Asking anyway is not
    /// an error: nothing is written and `AppliedRecipe.secondaryOutcome` records why.
    ///
    /// Nothing is ever written outside `secondary.output` and the primary destination — the
    /// `OptimizeRequest` write contract holds, which is why the URL is stated here rather than
    /// derived from the primary's.
    public var secondary: SecondaryRendition?

    public init(quality: QualityTarget = .balanced, resolution: ResolutionTarget = .source,
                enhance: EnhancePolicy = .off, upscale: UpscaleFactor = .none,
                output: OutputFormat = .auto, stripMetadata: Bool = false,
                integrity: IntegrityLevel = .structural,
                contentClass: ContentClassifier.ContentClass? = nil,
                cameraGate: CameraGate = .auto,
                secondary: SecondaryRendition? = nil) {
        self.contentClass = contentClass
        self.cameraGate = cameraGate
        self.secondary = secondary
        self.quality = quality
        self.resolution = resolution
        self.enhance = enhance
        self.upscale = upscale
        self.output = output
        self.stripMetadata = stripMetadata
        self.integrity = integrity
    }
}

/// A request for the secondary rendition (`Options.secondary`): the floor it must clear and the
/// exact URL it lands at. Both are required — a floor with nowhere to write is not a request, and a
/// URL is never derived from the primary's, because a host that names its outputs must keep naming
/// them.
public struct SecondaryRendition: Sendable {
    /// The SSIMULACRA2 floor the harvested candidate must have cleared. Meaningful only *below* the
    /// preset's own floor: at or above it, every qualifying candidate is the primary or larger, and
    /// the "strictly smaller than the primary" rule can only refuse.
    public var floor: Double
    /// Where the rendition lands. Left empty (nothing written, anything already there removed) when
    /// no candidate qualifies — same no-orphan rule the primary destination follows.
    public var output: URL

    public init(floor: Double, output: URL) {
        self.floor = floor
        self.output = output
    }
}

/// The delivered secondary rendition. Present only when one was asked for AND a candidate cleared
/// its floor AND that candidate is strictly smaller than what shipped as the primary (or than the
/// source, when the primary declined) — otherwise nil, and `AppliedRecipe.secondaryOutcome` says
/// which of those it was.
public struct SecondaryResult: Sendable {
    public let output: Output
    /// The floor this rendition cleared.
    public let floor: Double
    /// The floor the SEARCH was run at — the primary's. `floor` was never searched for, and the two
    /// numbers together are what make `provenance` sayable.
    public let searchFloor: Double
    public let bytes: Int
    public let width: Int
    public let height: Int
    /// Achieved p10 SSIMULACRA2, at or above `floor`.
    public let score: Double
    /// The reduction behind `score`, on the same terms as the primary's `MediaStats`.
    public let aggregation: MediaStats.QualityAggregation

    public init(output: Output, floor: Double, searchFloor: Double, bytes: Int,
                width: Int, height: Int, score: Double,
                aggregation: MediaStats.QualityAggregation) {
        self.output = output; self.floor = floor; self.searchFloor = searchFloor
        self.bytes = bytes; self.width = width; self.height = height
        self.score = score; self.aggregation = aggregation
    }

    /// How far ABOVE `floor` this rendition landed — the number that says whether the free version
    /// was good enough, or whether a dedicated `optimize` at `floor` is worth its minutes.
    ///
    /// A SMALL overshoot means the primary search's candidate ladder had probes near `floor`, so
    /// the harvest is close to what a real search would find. A LARGE one means the primary floor
    /// cleared early and the search never went looking down there. Measured on the signage corpus
    /// at floor 80 (2026-09-03, AB-A-0059), harvested bytes vs a dedicated `.balanced` run:
    /// overshoot 0.7 / 2.1 / 2.8 → **+9% / +10% / +10%**; overshoot 7.5 → **+171%** (10.61 MB where
    /// a dedicated search found 3.91 MB). Four masters is a calibration, not a fit — read it as
    /// "single digits good, high single digits worth a second look", not as a threshold.
    ///
    /// The corollary is the useful one for a host: the cases where the primary SKIPS — which is
    /// precisely when a second rung is needed at all — are the cases where the harvest is nearly
    /// optimal, because a search that could not reach its floor spent its whole ladder near the
    /// achievable ceiling.
    public var overshoot: Double { score - floor }

    /// **Put this in the ledger, not "optimized at \(floor)".** It is the difference between a
    /// rendition that was searched for and one that fell out of a search for something else — the
    /// first is the smallest file that clears `floor`, the second merely clears it. An operator who
    /// later needs the bytes can then ask for a dedicated run, knowing one was never made.
    public var provenance: String {
        String(format: "harvested @SSIMU2≥%.0f (from the ≥%.0f search)", floor, searchFloor)
    }
}

// MARK: - Pipeline request (host-dictated I/O)

/// A single pipeline work item: the host names the **exact output URL** (content-addressed; Forge writes
/// there, no post-move) and may attach an opaque `context` token echoed back on the result for entity
/// correlation. The destination-based `optimize(_:to:_)` stays the convenience path; this is the seam a
/// host (Marquee) drives. A future `operation:` field (which verb/chain to run) is deferred to the glue
/// layer — the request object is where it will slot in.
///
/// **`input` is strictly read-only (contract guarantee).** Forge READS the input and writes ONLY to
/// `output` (+ its own temp dir) — it never writes, moves, renames, or mutates the input. A host with a
/// write-once canonical original (Marquee's `Originals/`) can rely on it staying byte-identical.
public struct OptimizeRequest: Sendable {
    public var input: URL
    public var output: URL
    public var options: Options
    public var context: String?

    public init(input: URL, output: URL, options: Options = .init(), context: String? = nil) {
        self.input = input; self.output = output; self.options = options; self.context = context
    }
}

/// Progress for one item, emitted on both the destination-based and request-based paths.
///
/// Two dimensions travel together: `itemIndex`/`itemCount` locate the item in the submitted batch
/// (the outer bar), and `phase` + `fraction` + `detail` narrate the item itself. Today the video
/// path emits coarse stage transitions (preparing → searching → finalizing) with honest detail
/// lines; per-pass fractions and best-so-far lines arrive when the Kit adopts media-bridge's
/// `SearchProgress` callback (needs the 0.28.0 tag — the mapping seam is marked in
/// `optimizeVideo`). Stills are near-instant and emit bookends only. The handler fires on the
/// optimizer's task — hop to your actor/main thread before touching UI.
public struct OptimizeProgress: Sendable {
    public enum Phase: Sendable { case searching, encoding, scoring, finalizing }
    public let context: String?
    public let input: URL
    public let phase: Phase
    public let fraction: Double      // 0…1 within this item
    /// Human-readable stage line ("searching for the smallest H.264 that clears SSIMU2 ≥ 75…");
    /// nil when the phase alone tells the story.
    public let detail: String?
    /// This item's position in the submitted batch (0-based) and the batch size — the outer
    /// progress dimension a host combines with `fraction`.
    public let itemIndex: Int
    public let itemCount: Int

    public init(context: String?, input: URL, phase: Phase, fraction: Double,
                detail: String? = nil, itemIndex: Int = 0, itemCount: Int = 1) {
        self.context = context; self.input = input; self.phase = phase; self.fraction = fraction
        self.detail = detail; self.itemIndex = itemIndex; self.itemCount = itemCount
    }
}

// MARK: - Media kind

public enum MediaKind: String, Sendable { case image, video, unknown }

// MARK: - Receipt (the result of `optimize`)

public struct MediaStats: Sendable {
    public let bytes: Int
    public let width: Int
    public let height: Int
    public var qualityScore: Double?     // achieved SSIMULACRA2 on the output side; nil otherwise

    /// How a **video** score was reduced to `qualityScore` — nil for stills, where the score IS the frame.
    ///
    /// A video floor gates on a percentile over a sample, and `qualityScore` alone cannot say so: it is
    /// the same `Double` a still reports for its one frame. Carrying the reduction is what lets a receipt
    /// distinguish "every frame cleared the floor" from "the 10th percentile cleared it and the worst
    /// frame was well below" — both defensible, not the same claim (BRIDGE-061).
    ///
    /// **nil-for-stills is the point**: presence marks the number as an aggregate.
    public struct QualityAggregation: Sendable {
        public let percentile: Int
        public let minimum: Double
        public let mean: Double
        public let framesScored: Int
        public let frameCount: Int

        public init(percentile: Int, minimum: Double, mean: Double,
                    framesScored: Int, frameCount: Int) {
            self.percentile = percentile
            self.minimum = minimum
            self.mean = mean
            self.framesScored = framesScored
            self.frameCount = frameCount
        }

        public var summary: String {
            String(format: "p%d gate · min %.1f · mean %.1f · scored %d/%d frames",
                   percentile, minimum, mean, framesScored, frameCount)
        }
    }

    public var qualityAggregation: QualityAggregation?

    public init(bytes: Int, width: Int, height: Int, qualityScore: Double? = nil,
                qualityAggregation: QualityAggregation? = nil) {
        self.bytes = bytes
        self.width = width
        self.height = height
        self.qualityScore = qualityScore
        self.qualityAggregation = qualityAggregation
    }
}

/// What actually ran — a human-auditable record, not a request.
public struct AppliedRecipe: Sendable, CustomStringConvertible {
    public var normalized = false
    /// Container rewrap with byte-identical streams — no re-encode ran, so no floor and no score
    /// appear on the receipt: nothing lossy happened to measure.
    public var remuxed = false
    public var restored = false           // Phase B (NAFNet)
    /// The factor actually applied, **measured from the output pixels** — never the factor requested.
    ///
    /// BRIDGE-040: a fixed-4× model asked for 2× produced 4× pixels while the receipt said 2×. That was
    /// fixed in the model, but a receipt that reports the *request* is only ever accurate by luck — the
    /// next model that cannot honour a scale reopens it. Measuring the artifact cannot be lied to by any
    /// enhancer, present or future, and needs no cooperation from the enhance seam.
    public var upscaled: Int? = nil       // factor, Phase B (Real-ESRGAN / SeedVR2)
    /// What the caller asked for, when it differs from `upscaled`. Non-nil means the model did not
    /// honour the request — surfaced rather than silently normalised away.
    public var upscaleRequested: Int? = nil
    public var codec: String? = nil       // output format, e.g. "HEIC" / "HEVC"
    /// The `Options.stripMetadata` guarantee held for this deliverable: it carries no source
    /// metadata. On the receipt because a stripped file is indistinguishable from a clean-source
    /// file by looking — the claim has to ride with the artifact.
    public var strippedMetadata = false
    public var qualityFloor: Double? = nil
    /// The preset floor the class ratchet RAISED from, when it did (nil = no raise ran). The
    /// effective floor lives in `qualityFloor`; both appear on the receipt because a raised floor
    /// is a stronger promise than the preset made, and the reader deserves to know which held.
    public var floorRaisedFrom: Double? = nil
    /// The mechanically-detected content class that justified the raise (e.g. "graphic"). Set only
    /// alongside `floorRaisedFrom` — a classification that changed nothing is not receipt material.
    public var contentClass: String? = nil
    /// The quality floor was measured against a conservatively-DENOISED mezzanine, not the raw
    /// source (the consumer camera path: the clip's own noise probe proved the content noisy, and
    /// fidelity-to-noise is not the promise). The receipt must say which reference held the floor.
    public var denoisedReference: Bool = false
    /// What the consumer camera self-gate did on this item: `"off"` (`Options.cameraGate`),
    /// `"suppressed"` (an explicit `.graphic` class), `"clean"` (probed, no sensor noise),
    /// `"fired"` (probed noisy → denoised reference at the camera floor), or `"unavailable"` (the
    /// probe could not run on this OS/input). nil under every other preset, which never runs the
    /// gate. `denoisedReference` alone cannot separate "probed clean" from "never probed", and
    /// calibrating the gate's threshold needs exactly that split.
    public var cameraGate: String? = nil
    /// The source carried real transparency that the deliverable cannot: the GIF→mp4 web
    /// conversion composites over white by convention (a `<video>` has no alpha either). This is
    /// the one route where the Kit knowingly flattens, so the receipt says so — the flatten is
    /// invisible in the bytes and to the scorer.
    public var flattenedAlpha: Bool = false

    /// The secondary floor asked for (`Options.secondary.floor`), set whenever one was asked for —
    /// delivered or not. Paired with `secondaryOutcome`, which says what became of the request.
    public var secondaryFloor: Double? = nil
    /// What the secondary-rendition request produced on this item. nil when none was made.
    ///
    /// `"delivered"` · `"no-candidate"` (nothing the search encoded cleared the floor) ·
    /// `"not-smaller"` (something did, but not smaller than what ships — refused, because a
    /// rendition that isn't smaller is not one) · `"delivery-failed"` (a qualifying candidate
    /// existed and the copy failed — a disk fault, not a refusal, and worth retrying where the
    /// other two are not) · `"video-only"` (asked for on a still) · `"unsupported-route"` (asked
    /// for on a conversion path that encodes toward a different contract: GIF → web mp4,
    /// upscale → web, or a refusal).
    ///
    /// A string rather than a bool for the same reason `cameraGate` is one: "nothing shipped" has
    /// several distinct causes and each implies a different next move — only `"no-candidate"`,
    /// persistently and on content that CAN reach the floor, is an argument for spending a real
    /// second search.
    public var secondaryOutcome: String? = nil

    /// Planner-hint receipt trio (§6.3) — set ONLY when an injected `ContentHintProvider`'s hint
    /// CHANGED planner behavior: it raised the starting floor (`raised-*` outcomes) or it
    /// over-reached and the preset-floor search restored the contract (`overreached`). A hint that
    /// changed nothing is not receipt material — the same rule as `contentClass`. A hint-raised
    /// result also sets `floorRaisedFrom`/`contentClass`, so hinted and behavioral raises stay
    /// comparable in aggregates; `contentHintOutcome` is what tells them apart.
    public var contentHintClass: String? = nil
    public var contentHintConfidence: Double? = nil
    public var contentHintOutcome: String? = nil

    public init() {}

    /// Set `upscaled` from the pixels that actually came back, and record the request when it differs.
    ///
    /// A ratio within 2% of 1.0 counts as "no upscale happened" — reported as nil rather than as the
    /// requested factor, because claiming an upscale that did not occur is the original BRIDGE-040 lie
    /// in its purest form.
    public mutating func setUpscale(measuredFrom widthBefore: Int, to widthAfter: Int,
                                    requested: UpscaleFactor) {
        let asked: Int? = switch requested {
        case .none: nil
        case .x2: 2
        case .x4: 4
        }
        guard widthBefore > 0, widthAfter > 0 else { upscaled = nil; return }
        let ratio = Double(widthAfter) / Double(widthBefore)
        guard ratio > 1.02 else {
            upscaled = nil
            // Asked for an upscale and did not get one: that is the divergence worth surfacing.
            upscaleRequested = asked
            return
        }
        let actual = Int(ratio.rounded())
        upscaled = actual
        upscaleRequested = (asked != nil && asked != actual) ? asked : nil
    }

    public var description: String {
        var parts: [String] = []
        if remuxed { parts.append("remux (lossless)") }
        if normalized { parts.append("normalize") }
        if restored { parts.append("restore") }
        if let f = upscaled {
            if let asked = upscaleRequested, asked != f {
                parts.append("upscale×\(f) (asked ×\(asked))")
            } else {
                parts.append("upscale×\(f)")
            }
        }
        if let c = codec { parts.append("→\(c)") }
        if strippedMetadata { parts.append("strip-metadata") }
        if flattenedAlpha { parts.append("alpha-flattened (white)") }
        if let q = qualityFloor {
            if let base = floorRaisedFrom, let cls = contentClass {
                var raise = "raised from \(Int(base)) · \(cls)"
                switch contentHintOutcome {   // non-nil ⇒ the raise came from a pre-search hint
                case HintOutcome.confirmed.rawValue?:   raise += " · hinted"
                case HintOutcome.unconfirmed.rawValue?: raise += " · hinted, behavior disagreed"
                case HintOutcome.unverified.rawValue?:  raise += " · hinted, unverified"
                default: break
                }
                parts.append("@SSIMU2≥\(Int(q)) (\(raise))")
            } else if denoisedReference {
                // The camera path holds its floor against a DENOISED mezzanine rather than the raw
                // source — a different reference, so the receipt names it rather than implying
                // fidelity to the original grain.
                parts.append("@SSIMU2≥\(Int(q)) (camera · denoised ref)")
            } else {
                parts.append("@SSIMU2≥\(Int(q))")
                if contentHintOutcome == HintOutcome.overreached.rawValue {
                    parts.append("(hint overreached — preset floor kept)")
                }
            }
        }
        // A secondary rendition is a SECOND artifact, so it is stated as one rather than folded
        // into the primary's chain — and stated as harvested, never as a floor it was searched for.
        if let sf = secondaryFloor {
            switch secondaryOutcome {
            case "delivered"?: parts.append("+ harvested @SSIMU2≥\(Int(sf))")
            case let other?:   parts.append("+ no @SSIMU2≥\(Int(sf)) rendition (\(other))")
            case nil:          break
            }
        }
        return parts.isEmpty ? "passthrough" : parts.joined(separator: " ")
    }
}

public enum Output: Sendable {
    case file(URL)
    case data(Data)
    case none
}

public enum Status: Sendable {
    case optimized          // produced a smaller / cleaner output
    case skipped(String)    // already optimal — original kept
    case failed(String)     // per-item failure; a bulk run continues past it
}

public struct OptimizeResult: Sendable {
    public let input: URL
    public let kind: MediaKind
    public let output: Output
    public let recipe: AppliedRecipe
    public let before: MediaStats
    public let after: MediaStats
    public let status: Status
    public let elapsed: TimeInterval
    /// Opaque correlation token echoed from the `OptimizeRequest` (nil on the destination-based path) — the
    /// host maps a result back to its source entity without filename matching.
    public let context: String?
    /// **Authoritative output container/type.** Forge's optimize container is opinionated — **HEIC for
    /// stills, HEVC-in-mp4 for video** — independent of the `output` URL's extension. The host reads this to
    /// set its `content_type` (`outputType?.preferredMIMEType`) + deliverable extension
    /// (`outputType?.preferredFilenameExtension`). nil on `.skipped`/`.failed`.
    public let outputType: UTType?
    /// The weaker-floor rendition delivered beside the primary (`Options.secondary`), when one was.
    ///
    /// Independent of `status`: a `.skipped` primary with a non-nil `secondary` is the case the
    /// feature exists for — the floor could not be met at any size worth shipping, and the smaller
    /// rung is the only thing that ships. `savedBytes`/`Summary` deliberately ignore it: they
    /// describe what happened to the source, and the source still has exactly one primary.
    public let secondary: SecondaryResult?

    public init(input: URL, kind: MediaKind, output: Output, recipe: AppliedRecipe,
                before: MediaStats, after: MediaStats, status: Status, elapsed: TimeInterval,
                context: String? = nil, outputType: UTType? = nil,
                secondary: SecondaryResult? = nil) {
        self.input = input; self.kind = kind; self.output = output; self.recipe = recipe
        self.before = before; self.after = after; self.status = status; self.elapsed = elapsed
        self.context = context; self.outputType = outputType; self.secondary = secondary
    }

    public var savedBytes: Int { max(0, before.bytes - after.bytes) }
    public var savedFraction: Double {
        before.bytes > 0 ? Double(savedBytes) / Double(before.bytes) : 0
    }

    /// Same result with a correlation token attached (used by the request-based pipeline path).
    public func with(context: String?) -> OptimizeResult {
        OptimizeResult(input: input, kind: kind, output: output, recipe: recipe, before: before,
                       after: after, status: status, elapsed: elapsed, context: context,
                       outputType: outputType, secondary: secondary)
    }
}

/// Aggregate over a bulk run — yielded by the caller after the stream finishes.
public struct Summary: Sendable {
    public let count: Int
    public let optimized: Int
    public let skipped: Int
    public let failed: Int
    public let bytesIn: Int
    public let bytesOut: Int

    public var savedFraction: Double {
        bytesIn > 0 ? Double(max(0, bytesIn - bytesOut)) / Double(bytesIn) : 0
    }

    public init(_ results: [OptimizeResult]) {
        count = results.count
        optimized = results.filter { if case .optimized = $0.status { return true }; return false }.count
        skipped = results.filter { if case .skipped = $0.status { return true }; return false }.count
        failed = results.filter { if case .failed = $0.status { return true }; return false }.count
        bytesIn = results.reduce(0) { $0 + $1.before.bytes }
        // Only a delivery changes what's on disk. Skipped/failed keep the original, so they count at
        // `before.bytes` regardless of what their `after` carries — a trial encode's size (or a zero)
        // must never read as savings in the aggregate. Structural: even if a future path regresses
        // the receipt convention, the aggregate cannot claim savings from a non-delivery.
        bytesOut = results.reduce(0) { sum, r in
            if case .optimized = r.status { return sum + r.after.bytes }
            return sum + r.before.bytes
        }
    }
}

// MARK: - Analysis (the result of read-only `analyze`)

public struct SavingsEstimate: Sendable {
    public let estimatedFraction: Double?   // heuristic; nil when unknown without actually running
    public let note: String
}

/// One integrity check that actually ran during `analyze` — the receipt names its checks so a
/// verdict can never be read as a stronger claim than the tier that produced it.
public struct IntegrityCheck: Sendable, Equatable {
    public enum Outcome: String, Sendable { case passed, failed, skipped }
    public let name: String        // "box-chain", "png-chunks", "jpeg-eoi", "decode", "probe-sanity", …
    public let outcome: Outcome
    public let detail: String?

    public init(name: String, outcome: Outcome, detail: String? = nil) {
        self.name = name; self.outcome = outcome; self.detail = detail
    }
}

/// The integrity half of an `Analysis`.
///
/// - `intact`: every check that ran passed.
/// - `suspect`: structure is clean but a heuristic disagrees (absurd probed metadata, a probe that
///   cannot read a file whose bytes walk fine) — usable with eyes open.
/// - `corrupt`: a deterministic byte- or decode-level check failed; `detail` says which and where.
/// - `unverified`: nothing beyond readability could run (unknown format, IO error).
public struct IntegrityReport: Sendable {
    public enum Verdict: String, Sendable { case intact, suspect, corrupt, unverified }
    public let verdict: Verdict
    public let checks: [IntegrityCheck]

    public init(verdict: Verdict, checks: [IntegrityCheck]) {
        self.verdict = verdict; self.checks = checks
    }

    /// The first failure's diagnosis — nil when nothing failed.
    public var detail: String? { checks.first { $0.outcome == .failed }?.detail }

    /// One line fit for a log: the verdict plus the first diagnosis when there is one.
    public var summary: String {
        detail.map { "\(verdict.rawValue) — \($0)" } ?? verdict.rawValue
    }
}

public struct Analysis: Sendable {
    public let input: URL
    public let kind: MediaKind
    public let width: Int
    public let height: Int
    public let bytes: Int
    public let codecID: String
    public let qualityScore: Double?        // nil in Phase A (no-reference IQA arrives in Phase B)
    public let recommendation: AppliedRecipe
    public let estimate: SavingsEstimate
    /// Always present since 0.6.0: what integrity verification established for this file, at the
    /// tier `Options.integrity` selected. A file that cannot be probed no longer vanishes from the
    /// `analyze` stream — it yields an `Analysis` whose report says what is wrong with it.
    public let integrity: IntegrityReport
}

// MARK: - Conform (inter-segment glue for model pipelines, PRD §"conform")

public enum SizePolicy: Sendable {
    case exact(width: Int, height: Int)      // resize to exactly W×H (aspect may change)
    case fit(maxWidth: Int, maxHeight: Int)  // scale to fit inside, aspect preserved
    case fill(width: Int, height: Int)       // scale to cover, then center-crop to W×H
}

public enum ConformQuality: Sendable {
    case fast       // CoreGraphics high-quality resample — no model
    case quality    // Phase B: route spec upscales through Real-ESRGAN (engine)
}

public struct MediaSpec: Sendable {
    public var size: SizePolicy
    public var fps: Double?
    public var frameCount: Int?

    public init(size: SizePolicy, fps: Double? = nil, frameCount: Int? = nil) {
        self.size = size
        self.fps = fps
        self.frameCount = frameCount
    }
}

// MARK: - Errors

public enum ForgeError: Error, CustomStringConvertible {
    case unsupportedMedia(URL)
    case decodeFailed(URL)
    case renderFailed(String)
    case notImplemented(String)
    /// The request pairs options that contradict each other or the media kind (e.g. a stills
    /// format on video, `.heic` under the web verb, a pin against a host-pinned destination).
    /// Refused loudly: silently reinterpreting an explicit request is the no-op this replaces.
    case invalidOptions(String)
    case busy                       // single-flight: a run is already in progress (host owns any queueing)
    /// The host named an output path equal to the input. Refused rather than honoured: `OptimizeRequest`
    /// guarantees the input stays byte-identical, and a host relying on that (a write-once canonical
    /// original) would lose it silently. Derived destinations disambiguate instead; only an *explicit*
    /// `.fileURL` reaches here, because silently renaming an explicit instruction is its own dishonesty.
    case outputWouldOverwriteInput(URL)

    public var description: String {
        switch self {
        case .unsupportedMedia(let u): return "unsupported media: \(u.lastPathComponent)"
        case .decodeFailed(let u): return "decode failed: \(u.lastPathComponent)"
        case .outputWouldOverwriteInput(let u):
            return "output would overwrite the input (\(u.lastPathComponent)); the input is read-only"
        case .renderFailed(let s): return "render failed: \(s)"
        case .notImplemented(let s): return "not implemented: \(s)"
        case .invalidOptions(let s): return "invalid options: \(s)"
        case .busy: return "optimizer busy — a run is already in progress"
        }
    }
}
