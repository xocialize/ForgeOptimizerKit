import Foundation
import CoreGraphics

// conform — the in-memory inter-segment glue (PRD §"conform"). Resize/crop an artifact to the next
// pipeline stage's input spec. Phase A is image + `.fast` (CoreGraphics high-quality resample, fully
// headless — no CoreImage/Metal). `.quality` upscales route through Real-ESRGAN in Phase B.
//
// METAL-FRIENDLY DIRECTION (CLAUDE.md doctrine): this `CGImage` form is the headless/CLI + stills
// backend and the CPU fallback. The real pipeline/preview currency is `CVPixelBuffer`/`IOSurface`
// (GPU-resident, zero-copy with Metal + the MetalView preview). The `CVPixelBuffer` conform form, with
// a Metal-backed resampler (CoreImage Metal `CIContext` / MPS), lands with the frame loop / UI — built
// Metal-first. Keep this `CGImage` path as the fallback even then.

public extension ForgeOptimizer {

    /// Conform an image to `spec`. `.quality` currently falls back to `.fast` (engine routing = Phase B).
    func conform(_ image: CGImage, to spec: MediaSpec, _ quality: ConformQuality = .fast) throws -> CGImage {
        let srcW = Double(image.width), srcH = Double(image.height)
        switch spec.size {
        case .exact(let w, let h):
            return try resample(image, to: w, h, cropTo: nil)

        case .fit(let maxW, let maxH):
            let scale = min(Double(maxW) / srcW, Double(maxH) / srcH)
            let w = max(1, Int((srcW * scale).rounded()))
            let h = max(1, Int((srcH * scale).rounded()))
            return try resample(image, to: w, h, cropTo: nil)

        case .fill(let w, let h):
            let scale = max(Double(w) / srcW, Double(h) / srcH)   // cover
            let sw = max(w, Int((srcW * scale).rounded()))
            let sh = max(h, Int((srcH * scale).rounded()))
            return try resample(image, to: sw, sh, cropTo: (w, h))
        }
    }
}

/// Draw `image` into a `w×h` bitmap at high interpolation quality, optionally center-cropping to `cropTo`.
private func resample(_ image: CGImage, to w: Int, _ h: Int, cropTo: (Int, Int)?) throws -> CGImage {
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
