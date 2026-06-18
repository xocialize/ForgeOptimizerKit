import CoreGraphics

/// The Phase-B **enhance seam**. The net-clean, engine-free Kit defines this contract; the
/// engine-backed implementation — NAFNet restore → Real-ESRGAN upscale, driven through
/// `MLXServeEngine` (`register → prepare → run`) — lives in the **UI/app layer** that links the
/// engine. `optimize()` applies it to the decoded image *before* encode, but only when
/// `Options.enhance != .off` **and** an enhancer is supplied. This keeps the Kit headless + net-clean
/// (no MLX/engine dependency) while letting the app inject real model inference.
///
/// Async (the engine is async); `CGImage` is the Kit's still currency — the engine adapter converts
/// to/from the canonical `Image`/`CVPixelBuffer` internally (Metal-friendly doctrine, CLAUDE.md).
public protocol ImageEnhancer: Sendable {
    func enhance(_ image: CGImage, options: Options) async throws -> CGImage
}
