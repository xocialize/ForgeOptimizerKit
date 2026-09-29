//
// ReceiptJSON.swift — the NDJSON receipt, one shape for everyone.
//
// The `forge` CLI's `--json` receipts and any host that writes a batch manifest must agree byte for
// byte on what a receipt says — a second encoder is a second shape wearing the same name, and the
// drift shows up as "the app's numbers differ from the CLI's". So the encoder lives HERE and the CLI
// forwards to it. Keys are sorted so the output is stable for tooling; scores are `Decimal`s built
// from formatted strings so JSONSerialization prints "80.83", not "80.829999999999998".
//

import Foundation

public enum ReceiptJSON {

    /// One NDJSON line for `obj` (sorted keys, no trailing newline), or nil if it cannot serialize.
    public static func line(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// The bulk summary object the CLI ends a `--json` run with.
    public static func summary(_ s: Summary) -> [String: Any] {
        ["type": "summary", "count": s.count, "optimized": s.optimized,
         "skipped": s.skipped, "failed": s.failed,
         "bytes_in": s.bytesIn, "bytes_out": s.bytesOut,
         "saved_fraction": round4(s.savedFraction)]
    }

    public static func statusWord(_ s: Status) -> String {
        switch s {
        case .optimized: return "optimized"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }

    public static func round2(_ v: Double) -> Decimal { Decimal(string: String(format: "%.2f", v)) ?? 0 }

    public static func round4(_ v: Double) -> Decimal { Decimal(string: String(format: "%.4f", v)) ?? 0 }

    public static func stats(_ s: MediaStats) -> [String: Any] {
        var o: [String: Any] = ["bytes": s.bytes, "width": s.width, "height": s.height]
        if let q = s.qualityScore { o["ssimu2"] = round2(q) }
        if let a = s.qualityAggregation {
            o["aggregation"] = ["percentile": a.percentile, "min": round2(a.minimum),
                                "mean": round2(a.mean), "frames_scored": a.framesScored,
                                "frame_count": a.frameCount] as [String: Any]
        }
        return o
    }

    public static func result(_ r: OptimizeResult) -> [String: Any] {
        var o: [String: Any] = [
            "type": "result",
            "input": r.input.path,
            "kind": r.kind.rawValue,
            "status": statusWord(r.status),
            "recipe": String(describing: r.recipe),
            "before": stats(r.before),
            "after": stats(r.after),
            "saved_bytes": r.savedBytes,
            "saved_fraction": round4(r.savedFraction),
            "elapsed_s": round2(r.elapsed),
        ]
        // Floor/class/hint receipts, structured (the recipe string above carries them for
        // humans). These rows are the §6.5 training-set flywheel — and the §6.3 disagreement
        // receipt lands here as `hint_outcome`.
        if let q = r.recipe.qualityFloor { o["quality_floor"] = q }
        if let base = r.recipe.floorRaisedFrom { o["floor_raised_from"] = base }
        if let cls = r.recipe.contentClass { o["content_class"] = cls }
        // The gate's disposition rides on the receipt so calibration rows can separate
        // "probed clean" from "never probed" (--no-camera-gate / --content-class graphic).
        if let gate = r.recipe.cameraGate { o["camera_gate"] = gate }
        if r.recipe.flattenedAlpha { o["flattened_alpha"] = true }
        // The upscale, structured: the factor measured from the pixels, and the tier + model the
        // enhancer REPORTED running — each key present only when there is something to say.
        if let f = r.recipe.upscaled { o["upscaled"] = f }
        if let asked = r.recipe.upscaleRequested { o["upscale_requested"] = asked }
        if let tier = r.recipe.upscaleTier { o["upscale_tier"] = tier.rawValue }
        if let model = r.recipe.upscaleModel { o["upscale_model"] = model }
        if let askedTier = r.recipe.upscaleTierRequested { o["upscale_tier_requested"] = askedTier.rawValue }
        if let hintClass = r.recipe.contentHintClass {
            o["hint_class"] = hintClass
            if let c = r.recipe.contentHintConfidence { o["hint_confidence"] = round2(c) }
            if let outcome = r.recipe.contentHintOutcome { o["hint_outcome"] = outcome }
        }
        // The secondary rung, structured. `provenance` ships with it deliberately: a ledger that
        // records the score without it will read as "optimized at 80", which is the one claim this
        // rendition cannot make (AB-A-0059).
        if let floor = r.recipe.secondaryFloor {
            var sec: [String: Any] = ["floor": floor,
                                      "outcome": r.recipe.secondaryOutcome ?? "unknown"]
            if let s2 = r.secondary {
                sec["ssimu2"] = round2(s2.score)
                sec["search_floor"] = s2.searchFloor
                sec["bytes"] = s2.bytes
                sec["width"] = s2.width
                sec["height"] = s2.height
                sec["provenance"] = s2.provenance
                // Small ⇒ close to what a dedicated search would find; large ⇒ the ladder never
                // approached this floor (see `SecondaryResult.overshoot` for the measured split).
                sec["overshoot"] = round2(s2.overshoot)
                sec["aggregation"] = ["percentile": s2.aggregation.percentile,
                                      "min": round2(s2.aggregation.minimum),
                                      "mean": round2(s2.aggregation.mean),
                                      "frames_scored": s2.aggregation.framesScored,
                                      "frame_count": s2.aggregation.frameCount] as [String: Any]
                if case .file(let u) = s2.output { sec["output"] = u.path }
            }
            o["secondary"] = sec
        }
        switch r.output {
        case .file(let u):  o["output"] = u.path
        case .data(let d):  o["output_inline_bytes"] = d.count
        case .none:         break
        }
        switch r.status {
        case .skipped(let why), .failed(let why): o["reason"] = why
        case .optimized: break
        }
        if let mime = r.outputType?.preferredMIMEType { o["mime"] = mime }
        // Machine-readable strip claim — a host must not have to parse the recipe prose for it.
        if r.recipe.strippedMetadata { o["stripped_metadata"] = true }
        return o
    }

    public static func analysis(_ a: Analysis) -> [String: Any] {
        var o: [String: Any] = [
            "type": "analysis",
            "input": a.input.path,
            "kind": a.kind.rawValue,
            "width": a.width, "height": a.height,
            "bytes": a.bytes,
            "codec": a.codecID,
            "recommendation": String(describing: a.recommendation),
            "integrity": ["verdict": a.integrity.verdict.rawValue,
                          "checks": a.integrity.checks.map {
                              var c: [String: Any] = ["name": $0.name, "outcome": $0.outcome.rawValue]
                              if let d = $0.detail { c["detail"] = d }
                              return c
                          }] as [String: Any],
            "estimate_note": a.estimate.note,
        ]
        if let q = a.qualityScore { o["quality_score"] = round2(q) }
        if let f = a.estimate.estimatedFraction { o["estimated_fraction"] = round4(f) }
        return o
    }
}
