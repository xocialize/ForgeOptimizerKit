import Foundation

// The product-facing quality preset — the named surface every host (the standalone app, Marquee Studio)
// presents and picks from. It maps to the Kit's generic `QualityTarget` floor that `optimize` honors.
// One canonical ladder so every consumer of the embedded UI shows the SAME tiers (parity across hosts).
//
// Presets carry an intent label, NOT a savings promise — actual savings are media-dependent (a 4K video
// master compresses ~64% at Balanced; a still ~86%) and surface from the real receipt, never as a
// fabricated badge on the picker.

public struct Preset: Sendable, Identifiable {
    public let id: String
    public let name: String         // display label, e.g. "Visually Lossless"
    public let floorLabel: String   // the quality anchor, e.g. "SSIMU2 ≥ 90"
    public let useCase: String      // who it's for, e.g. "Hero · archival"
    public let quality: QualityTarget

    public init(id: String, name: String, floorLabel: String, useCase: String, quality: QualityTarget) {
        self.id = id
        self.name = name
        self.floorLabel = floorLabel
        self.useCase = useCase
        self.quality = quality
    }

    public var floor: Double { quality.floor }
}

public extension Preset {
    /// ≥ 90 — visually lossless (not noticeable in a flicker test). The **brand-safe default a signage
    /// host selects** for client masters; generic hosts default to `.balanced`.
    static let visuallyLossless = Preset(
        id: "visually-lossless", name: "Visually Lossless",
        floorLabel: "SSIMU2 ≥ 90", useCase: "Hero · brand-safe", quality: .max)

    /// ≥ 80 — very high; not noticeable side-by-side. The generic default.
    static let balanced = Preset(
        id: "balanced", name: "Balanced",
        floorLabel: "SSIMU2 ≥ 80", useCase: "Default", quality: .balanced)

    /// ≥ 70 — high; the standard distribution target (smallest acceptable).
    static let aggressive = Preset(
        id: "aggressive", name: "Aggressive",
        floorLabel: "SSIMU2 ≥ 70", useCase: "Distribution", quality: .aggressive)

    /// The canonical ladder, highest-floor first. Hosts render this verbatim for parity; a host may
    /// present a subset (e.g. signage might show only Visually Lossless + Balanced) but should not
    /// invent floors outside it without a deliberate `.custom` preset.
    static let standard: [Preset] = [.visuallyLossless, .balanced, .aggressive]

    /// The preset in `standard` whose floor matches `target`, if any (for reflecting an `Options` choice
    /// back onto the picker selection).
    static func matching(_ target: QualityTarget) -> Preset? {
        standard.first { $0.floor == target.floor }
    }
}

public extension Options {
    /// Build options from a named preset — the clean entry point for a host (Marquee Studio) wiring its
    /// optimize action: `Options(preset: .visuallyLossless)` or `Options(preset: .visuallyLossless,
    /// resolution: .maxHeight(1080))` to also step 4K→HD.
    init(preset: Preset, resolution: ResolutionTarget = .source, enhance: EnhancePolicy = .off,
         upscale: UpscaleFactor = .none, output: OutputFormat = .auto, stripMetadata: Bool = false) {
        self.init(quality: preset.quality, resolution: resolution, enhance: enhance,
                  upscale: upscale, output: output, stripMetadata: stripMetadata)
    }
}
