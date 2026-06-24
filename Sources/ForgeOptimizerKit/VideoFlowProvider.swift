import CoreGraphics
import MediaMeasure

/// The Phase-B **optical-flow seam** for temporally-consistent video upscale (SEA-RAFT) — the video analog of
/// `ImageEnhancer`. The net-clean Kit defines this contract; the engine-backed implementation injects from the
/// UI/app layer (keeping the Kit MLX-free). Returns the dense cur→prev flow `VideoConsistencyProcessor` uses to
/// stabilize per-frame super-resolution. When **no** provider is injected, the upscale path runs per-frame SR
/// with no temporal stabilization (zero flow) — so upscale still works engine-free, just without flicker
/// suppression. (Estimated on the cheap source frames; the field is upscaled to output res internally.)
public protocol VideoFlowProvider: Sendable {
    func flow(_ a: CGImage, _ b: CGImage) async throws -> DenseFlow
}
