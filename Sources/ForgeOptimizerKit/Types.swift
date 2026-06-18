import Foundation

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
    case aggressive   // ≥ 70 — high; the standard distribution target (smallest acceptable)
    case custom(Double)

    public var floor: Double {
        switch self {
        case .max: return 90
        case .balanced: return 80
        case .aggressive: return 70
        case .custom(let v): return v
        }
    }
}

public enum EnhancePolicy: Sendable { case off, auto, on }   // Phase A honors only `.off`
public enum UpscaleFactor: Sendable { case none, x2, x4 }    // Phase B (engine / Real-ESRGAN)
public enum OutputFormat: Sendable { case auto, heic, jpeg, png, hevc }  // `.auto` = per media kind

public struct Options: Sendable {
    public var quality: QualityTarget
    public var enhance: EnhancePolicy
    public var upscale: UpscaleFactor
    public var output: OutputFormat
    public var stripMetadata: Bool

    public init(quality: QualityTarget = .balanced, enhance: EnhancePolicy = .off,
                upscale: UpscaleFactor = .none, output: OutputFormat = .auto,
                stripMetadata: Bool = false) {
        self.quality = quality
        self.enhance = enhance
        self.upscale = upscale
        self.output = output
        self.stripMetadata = stripMetadata
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

    public init(bytes: Int, width: Int, height: Int, qualityScore: Double? = nil) {
        self.bytes = bytes
        self.width = width
        self.height = height
        self.qualityScore = qualityScore
    }
}

/// What actually ran — a human-auditable record, not a request.
public struct AppliedRecipe: Sendable, CustomStringConvertible {
    public var normalized = false
    public var restored = false           // Phase B (NAFNet)
    public var upscaled: Int? = nil       // factor, Phase B (Real-ESRGAN / SeedVR2)
    public var codec: String? = nil       // output format, e.g. "HEIC" / "HEVC"
    public var qualityFloor: Double? = nil

    public init() {}

    public var description: String {
        var parts: [String] = []
        if normalized { parts.append("normalize") }
        if restored { parts.append("restore") }
        if let f = upscaled { parts.append("upscale×\(f)") }
        if let c = codec { parts.append("→\(c)") }
        if let q = qualityFloor { parts.append("@SSIMU2≥\(Int(q))") }
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

    public var savedBytes: Int { max(0, before.bytes - after.bytes) }
    public var savedFraction: Double {
        before.bytes > 0 ? Double(savedBytes) / Double(before.bytes) : 0
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
        bytesOut = results.reduce(0) { $0 + $1.after.bytes }
    }
}

// MARK: - Analysis (the result of read-only `analyze`)

public struct SavingsEstimate: Sendable {
    public let estimatedFraction: Double?   // heuristic; nil when unknown without actually running
    public let note: String
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

    public var description: String {
        switch self {
        case .unsupportedMedia(let u): return "unsupported media: \(u.lastPathComponent)"
        case .decodeFailed(let u): return "decode failed: \(u.lastPathComponent)"
        case .renderFailed(let s): return "render failed: \(s)"
        case .notImplemented(let s): return "not implemented: \(s)"
        }
    }
}
