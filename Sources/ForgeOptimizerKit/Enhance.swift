import CoreGraphics
import Foundation

/// The Phase-B **enhance seam**. The net-clean, engine-free Kit defines this contract; the
/// engine-backed implementation — NAFNet restore → NERVE (`.fast`) or RealPLKSR (`.best`) upscale,
/// driven through `MLXServeEngine` (`register → prepare → run`) — lives in ForgeCore, which links
/// the engine. `optimize()` applies it to the decoded image *before* encode, but only when
/// `Options.enhance != .off` **and** an enhancer is supplied. This keeps the Kit headless + net-clean
/// (no MLX/engine dependency) while letting the app inject real model inference.
///
/// Async (the engine is async); `CGImage` is the Kit's still currency — the engine adapter converts
/// to/from the canonical `Image`/`CVPixelBuffer` internally (Metal-friendly doctrine, CLAUDE.md).
public protocol ImageEnhancer: Sendable {
    func enhance(_ image: CGImage, options: Options) async throws -> CGImage

    /// `enhance`, plus what actually ran. The Kit calls this form, so the receipt's upscale tier
    /// and model are what the enhancer reports from its own run — never read back off `options`.
    ///
    /// Default: `enhance`, reporting nothing. A receipt from an enhancer that does not report
    /// names no tier and no model rather than inferring them from the request.
    func enhanceReporting(_ image: CGImage, options: Options) async throws -> EnhanceOutcome

    /// Whether this enhancer can run `tier` now, and if not, why. The Kit asks before every
    /// upscale and fails the item on an unavailable tier, so a tier the enhancer cannot honour is
    /// refused rather than swapped for the other one; a UI asks it to show a choice as unavailable
    /// with its reason.
    ///
    /// Default: a single tier — `.fast` available, `.best` not. An enhancer that predates tiers
    /// runs whatever it runs, and offering a choice it would ignore is exactly the silent fallback
    /// this seam exists to prevent. `.liveAction` is never an enhancer's: it is a whole-clip video
    /// tier (`VideoUpscaler`), and the Kit refuses it on a still before asking.
    func availability(of tier: UpscaleTier) async -> UpscaleTierAvailability
}

public extension ImageEnhancer {
    func enhanceReporting(_ image: CGImage, options: Options) async throws -> EnhanceOutcome {
        EnhanceOutcome(image: try await enhance(image, options: options))
    }

    func availability(of tier: UpscaleTier) async -> UpscaleTierAvailability {
        switch tier {
        case .fast: return .available(.fast)
        case .best: return .unavailable(.best, reason: "this enhancer offers a single upscale tier")
        case .liveAction: return .unavailable(.liveAction, reason: UpscaleTier.liveActionStillReason)
        }
    }
}

/// What one enhance call actually did, as the enhancer observed it from its own models' responses.
public struct EnhanceOutcome: Sendable {
    public var image: CGImage
    /// The tier whose backer ran the upscale; nil when no upscale ran (or the enhancer cannot say).
    public var upscaleTier: UpscaleTier?
    /// That backer's model name ("NERVE", "RealPLKSR"); nil likewise.
    public var upscaleModel: String?

    public init(image: CGImage, upscaleTier: UpscaleTier? = nil, upscaleModel: String? = nil) {
        self.image = image
        self.upscaleTier = upscaleTier
        self.upscaleModel = upscaleModel
    }
}

/// An enhancer's answer to "can you run this upscale tier here?" — the state a UI renders.
///
/// `model` is routing — the backer the enhancer *would* run — and may be named even when the tier
/// is unavailable, so the reason can say which model is missing. What actually ran is the receipt's
/// business (`AppliedRecipe.upscaleModel`).
public struct UpscaleTierAvailability: Sendable, Equatable {
    public let tier: UpscaleTier
    public let model: String?
    /// Why the tier cannot run, in the user's terms; nil means it can.
    public let unavailableReason: String?

    public var isAvailable: Bool { unavailableReason == nil }

    public init(tier: UpscaleTier, model: String? = nil, unavailableReason: String? = nil) {
        self.tier = tier
        self.model = model
        self.unavailableReason = unavailableReason
    }

    public static func available(_ tier: UpscaleTier, model: String? = nil) -> Self {
        Self(tier: tier, model: model)
    }

    public static func unavailable(_ tier: UpscaleTier, model: String? = nil, reason: String) -> Self {
        Self(tier: tier, model: model, unavailableReason: reason)
    }
}

/// Collects what each frame's enhance reported, so a video receipt names the backer only when the
/// frames agree on it. Frames that disagree — which only an enhancer that substituted mid-clip can
/// produce — keep no tier and list every model, in the order they first ran: claiming one backer for
/// a clip that had two would be a receipt describing a file that does not exist.
final class BackerTally: @unchecked Sendable {
    private let lock = NSLock()
    private var tiers: [UpscaleTier?] = []
    private var models: [String] = []

    func note(_ outcome: EnhanceOutcome) {
        lock.lock(); defer { lock.unlock() }
        if !tiers.contains(outcome.upscaleTier) { tiers.append(outcome.upscaleTier) }
        if let model = outcome.upscaleModel, !models.contains(model) { models.append(model) }
    }

    var summary: (tier: UpscaleTier?, model: String?) {
        lock.lock(); defer { lock.unlock() }
        let tier = tiers.count == 1 ? tiers[0] : nil
        return (tier, models.isEmpty ? nil : models.joined(separator: "+"))
    }
}
