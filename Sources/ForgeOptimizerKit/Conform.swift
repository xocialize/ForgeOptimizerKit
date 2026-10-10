import Foundation
import CoreGraphics
import MediaMetrics

// conform — the in-memory inter-segment glue (PRD §"conform"). Resize/crop an artifact to the next
// pipeline stage's input spec. `.fast` is a CoreGraphics high-quality resample, fully headless (no
// CoreImage/Metal). `.quality(tier)` runs only the UPSCALE part of a conform through the injected
// `ImageEnhancer`'s upscale-only path at the tier the caller names (ForgeCore: NERVE for `.fast`,
// RealPLKSR for `.best`), then resamples the model's pixels to exactly the spec. Downscales and crops
// never touch a model, and a quality upscale that cannot run fails — it is never interpolated instead.
//
// METAL-FRIENDLY DIRECTION (CLAUDE.md doctrine): this `CGImage` form is the headless/CLI + stills
// backend and the CPU fallback. The real pipeline/preview currency is `CVPixelBuffer`/`IOSurface`
// (GPU-resident, zero-copy with Metal + the MetalView preview). The `CVPixelBuffer` conform form, with
// a Metal-backed resampler (CoreImage Metal `CIContext` / MPS), lands with the frame loop / UI — built
// Metal-first. Keep this `CGImage` path as the fallback even then.

public extension ForgeOptimizer {

    /// Conform an image to `spec` with a CoreGraphics high-quality resample — the `.fast` path,
    /// synchronous and model-free. A model-backed upscale is `conform(_:to:quality:)`.
    func conform(_ image: CGImage, to spec: MediaSpec) throws -> CGImage {
        try ConformPlan(spec, sourceWidth: image.width, sourceHeight: image.height).resample(image)
    }

    /// Conform an image to `spec`, reporting what ran.
    ///
    /// `.fast` is the CoreGraphics resample. `.quality(tier)` runs the conform's upscale through the
    /// injected enhancer's upscale-only path (`ImageEnhancer.upscaleReporting` — no restore: a conform
    /// is resize glue and must not change the content the next stage receives). The model runs ×2 when
    /// the spec needs at most twice the source in both axes and ×4 up to four times; its pixels are then
    /// resampled to exactly the spec. A conform that does not enlarge the source in either axis (a
    /// downscale, a crop) needs no model: it runs the CoreGraphics resample and the result names none.
    ///
    /// A quality upscale fails rather than run `.fast` in its place:
    /// - no enhancer attached, the tier video-only, the tier unavailable (`availability(of:)`'s reason),
    ///   or an enhancer without an upscale-only path → `ForgeError.upscaleTierUnavailable`;
    /// - more than ×4 in either axis → `ForgeError.invalidOptions` (one model pass; conform in two steps);
    /// - the enhancer reporting a different tier from the one asked, or returning fewer pixels than the
    ///   spec needs → `ForgeError.renderFailed`, because either would put another model's pixels, or
    ///   interpolated ones, under the requested tier's name.
    func conform(_ image: CGImage, to spec: MediaSpec, quality: ConformQuality) async throws -> ConformResult {
        let plan = ConformPlan(spec, sourceWidth: image.width, sourceHeight: image.height)
        guard case .quality(let tier) = quality else {
            return ConformResult(image: try plan.resample(image), quality: quality)
        }
        // A whole-clip tier can never serve a still, whatever the geometry: refused on every call.
        if tier.isVideoOnly {
            throw ForgeError.upscaleTierUnavailable(tier, UpscaleTier.liveActionStillReason)
        }
        guard plan.upscales(image.width, image.height) else {
            return ConformResult(image: try plan.resample(image), quality: quality)
        }
        guard let factor = plan.modelFactor(image.width, image.height) else {
            throw ForgeError.invalidOptions(
                "a quality conform of \(image.width)×\(image.height) to \(plan.width)×\(plan.height) needs more "
                + "than ×8; a model upscale runs at most ×8 (×4, then ×2 on the fast fidelity tier — AB-D-0119) — conform in two steps")
        }
        guard let enhancer else {
            throw ForgeError.upscaleTierUnavailable(
                tier, "no enhancer is attached to this optimizer — a quality conform's upscale needs one")
        }
        try await Self.requireStillUpscaleTier(tier, of: enhancer)

        let outcome = try await MediaMetrics.time("kit.conform.upscale", lane: "gpu",
                                                  attrs: ["w": "\(image.width)", "h": "\(image.height)",
                                                          "tier": tier.rawValue]) {
            try await enhancer.upscaleReporting(image, factor: factor, tier: tier)
        }
        let upscaled = outcome.image
        let backer = [outcome.upscaleTier?.rawValue, outcome.upscaleModel].compactMap { $0 }.joined(separator: " · ")

        // Reported, never assumed: an enhancer that ran another tier anyway is refused, not returned
        // under the requested name (the receipt surfaces this for optimize; a conform has no receipt
        // to surface it in, so the call fails).
        if let ran = outcome.upscaleTier, ran != tier {
            throw ForgeError.renderFailed(
                "the enhancer reported running the '\(ran.rawValue)' tier (\(backer)) for a '\(tier.rawValue)' "
                + "quality conform — refused rather than returned under the wrong tier")
        }
        // The model's pixels must cover the spec, so the final resample only ever reduces them. A 2%
        // tolerance absorbs alignment trims (the Kit's `setUpscale` rule); anything shorter would make
        // the rest of the upscale an interpolation under the model's name.
        if Double(upscaled.width) < 0.98 * Double(plan.width) || Double(upscaled.height) < 0.98 * Double(plan.height) {
            throw ForgeError.renderFailed(
                "the enhancer's ×\(factor.multiplier) upscale\(backer.isEmpty ? "" : " (\(backer))") returned "
                + "\(upscaled.width)×\(upscaled.height) from \(image.width)×\(image.height), short of the "
                + "\(plan.width)×\(plan.height) this conform needs — the rest would be interpolation")
        }
        return ConformResult(
            image: try plan.resample(upscaled), quality: quality,
            modelScale: Int((Double(upscaled.width) / Double(image.width)).rounded()),
            upscaleTier: outcome.upscaleTier, upscaleModel: outcome.upscaleModel)
    }
}

/// The CoreGraphics resample a spec asks for: draw the source at `width×height`, then center-crop to
/// `crop` (`.fill` only).
struct ConformPlan {
    let width: Int
    let height: Int
    let crop: (width: Int, height: Int)?

    init(_ spec: MediaSpec, sourceWidth: Int, sourceHeight: Int) {
        let srcW = Double(sourceWidth), srcH = Double(sourceHeight)
        switch spec.size {
        case .exact(let w, let h):
            (width, height, crop) = (w, h, nil)

        case .fit(let maxW, let maxH):
            let scale = min(Double(maxW) / srcW, Double(maxH) / srcH)
            width = max(1, Int((srcW * scale).rounded()))
            height = max(1, Int((srcH * scale).rounded()))
            crop = nil

        case .fill(let w, let h):
            let scale = max(Double(w) / srcW, Double(h) / srcH)   // cover
            width = max(w, Int((srcW * scale).rounded()))
            height = max(h, Int((srcH * scale).rounded()))
            crop = (w, h)
        }
    }

    /// Whether the draw enlarges a `w×h` source in either axis — the only part of a conform a model serves.
    func upscales(_ w: Int, _ h: Int) -> Bool { width > w || height > h }

    /// The smallest model factor whose output covers the draw in both axes; nil past ×8. ×6 and ×8 are
    /// served by the enhancer as a chain (`UpscaleFactor`), so a conform that needs them asks for them
    /// the same way and resamples the result to the exact spec as before.
    func modelFactor(_ w: Int, _ h: Int) -> UpscaleFactor? {
        if width <= 2 * w && height <= 2 * h { return .x2 }
        if width <= 4 * w && height <= 4 * h { return .x4 }
        if width <= 6 * w && height <= 6 * h { return .x6 }
        if width <= 8 * w && height <= 8 * h { return .x8 }
        return nil
    }

    func resample(_ image: CGImage) throws -> CGImage {
        try drawResampled(image, to: width, height, cropTo: crop)
    }
}

extension UpscaleFactor {
    /// The integer factor, 1 for `.none`.
    var multiplier: Int {
        switch self {
        case .none: return 1
        case .x2: return 2
        case .x4: return 4
        case .x6: return 6
        case .x8: return 8
        }
    }
}

/// Draw `image` into a `w×h` bitmap at high interpolation quality, optionally center-cropping to `cropTo`.
private func drawResampled(_ image: CGImage, to w: Int, _ h: Int, cropTo: (width: Int, height: Int)?) throws -> CGImage {
    let rgb = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ForgeError.renderFailed("CGContext \(w)×\(h)")
    }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let scaled = ctx.makeImage() else { throw ForgeError.renderFailed("makeImage") }

    guard let (cw, ch) = cropTo else { return scaled }
    let x = (w - cw) / 2, y = (h - ch) / 2
    guard let cropped = scaled.cropping(to: CGRect(x: x, y: y, width: cw, height: ch)) else {
        throw ForgeError.renderFailed("crop \(cw)×\(ch)")
    }
    return cropped
}
