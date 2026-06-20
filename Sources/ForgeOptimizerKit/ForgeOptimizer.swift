import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MediaBridge
import ImageBridge
import MediaMeasure

/// The headless ForgeOptimizer core. Phase A runs entirely on media-bridge (pure-Swift, FFmpeg-free):
/// structural `analyze`, target-quality `optimize`, and `.fast` `conform`. No MLX, no metallib —
/// build + test from the CLI. The engine (enhance, perceptual analyze, `.quality` conform) is Phase B.
public struct ForgeOptimizer: Sendable {

    /// Phase-B engine-backed restore/upscale (supplied by the UI/app layer). `nil` = media-bridge-only;
    /// the Kit stays engine-free. Applied before encode when `Options.enhance != .off`.
    private let enhancer: (any ImageEnhancer)?

    public init(enhancer: (any ImageEnhancer)? = nil) {
        self.enhancer = enhancer
    }

    // MARK: - analyze (read-only)

    /// Probe + recommend, without writing anything. Best-effort per item: a file that can't be probed
    /// is simply omitted from the stream (a hard contract failure is a programming error, not data).
    public func analyze(_ source: Source, _ options: Options = .init()) -> AsyncStream<Analysis> {
        let urls = source.urls
        return AsyncStream { continuation in
            Task {
                for url in urls {
                    if let analysis = try? await analyzeOne(url, options) {
                        continuation.yield(analysis)
                    }
                }
                continuation.finish()
            }
        }
    }

    private func analyzeOne(_ url: URL, _ options: Options) async throws -> Analysis {
        let bytes = fileSize(url)
        switch mediaKind(of: url) {
        case .image:
            let meta = try ImageBridgeFactory.makeProbe().probe(url: url)
            var recipe = AppliedRecipe()
            recipe.codec = "HEIC"
            recipe.qualityFloor = options.quality.floor
            recipe.normalized = meta.format != .heic
            let estimate = SavingsEstimate(
                estimatedFraction: nil,
                note: "run optimize for actual savings (target SSIMULACRA2 ≥ \(Int(options.quality.floor)))")
            return Analysis(input: url, kind: .image, width: meta.width, height: meta.height,
                            bytes: bytes, codecID: meta.format.rawValue, qualityScore: nil,
                            recommendation: recipe, estimate: estimate)
        case .video:
            let info = try await MediaBridge.probe(url: url)
            let v = info.videoStreams.first
            var recipe = AppliedRecipe()
            recipe.codec = "HEVC"
            recipe.normalized = !info.container.isNativeApple
            let estimate = SavingsEstimate(
                estimatedFraction: nil,
                note: "video target-quality pending per-frame aggregation; optimize = normalize")
            return Analysis(input: url, kind: .video, width: v?.width ?? 0, height: v?.height ?? 0,
                            bytes: bytes, codecID: v?.codecID ?? "?", qualityScore: nil,
                            recommendation: recipe, estimate: estimate)
        case .unknown:
            throw ForgeError.unsupportedMedia(url)
        }
    }

    // MARK: - optimize

    /// Stream a receipt per input. Per-item failures are isolated (yielded as `.failed`), so one bad
    /// file never aborts a bulk run. Throws only on up-front contract errors (e.g. unwritable folder).
    public func optimize(_ source: Source, to destination: Destination,
                         _ options: Options = .init()) throws -> AsyncStream<OptimizeResult> {
        try prepareDestination(destination)
        let urls = source.urls
        return AsyncStream { continuation in
            Task {
                for url in urls {
                    let start = Date()
                    do {
                        continuation.yield(try await optimizeOne(url, to: destination, options, start: start))
                    } catch {
                        let bytes = fileSize(url)
                        continuation.yield(OptimizeResult(
                            input: url, kind: mediaKind(of: url), output: .none, recipe: AppliedRecipe(),
                            before: MediaStats(bytes: bytes, width: 0, height: 0),
                            after: MediaStats(bytes: bytes, width: 0, height: 0),
                            status: .failed("\(error)"), elapsed: Date().timeIntervalSince(start)))
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Pipeline entry: each `OptimizeRequest` names its **exact output URL** and an optional `context`
    /// token (echoed on the result). Per-item failures are isolated. `progress` is **stubbed** — only the
    /// terminal `.searching`(0) → `.finalizing`(1) bookends fire today (per-iteration granularity is the
    /// deferred implementation). Single-flight + busy-rejection live in `ForgeOptimizerService`, not here.
    public func optimize(_ requests: [OptimizeRequest],
                         progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        -> AsyncStream<OptimizeResult> {
        AsyncStream { continuation in
            Task {
                for req in requests {
                    let start = Date()
                    progress?(OptimizeProgress(context: req.context, input: req.input,
                                               phase: .searching, fraction: 0))
                    do {
                        try prepareDestination(.fileURL(req.output))
                        let r = try await optimizeOne(req.input, to: .fileURL(req.output), req.options,
                                                      start: start)
                        continuation.yield(r.with(context: req.context))
                    } catch {
                        let bytes = fileSize(req.input)
                        continuation.yield(OptimizeResult(
                            input: req.input, kind: mediaKind(of: req.input), output: .none,
                            recipe: AppliedRecipe(), before: MediaStats(bytes: bytes, width: 0, height: 0),
                            after: MediaStats(bytes: bytes, width: 0, height: 0),
                            status: .failed("\(error)"), elapsed: Date().timeIntervalSince(start),
                            context: req.context))
                    }
                    progress?(OptimizeProgress(context: req.context, input: req.input,
                                               phase: .finalizing, fraction: 1))
                }
                continuation.finish()
            }
        }
    }

    private func optimizeOne(_ url: URL, to destination: Destination, _ options: Options,
                             start: Date) async throws -> OptimizeResult {
        switch mediaKind(of: url) {
        case .image: return try await optimizeImage(url, to: destination, options, start: start)
        case .video: return try await optimizeVideo(url, to: destination, options, start: start)
        case .unknown: throw ForgeError.unsupportedMedia(url)
        }
    }

    /// Image path: optional engine enhance → target-quality HEIC via media-bridge's SSIMULACRA2 search.
    private func optimizeImage(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date) async throws -> OptimizeResult {
        let inBytes = fileSize(url)
        guard var cg = loadCGImage(url) else { throw ForgeError.decodeFailed(url) }

        var recipe = AppliedRecipe()
        recipe.codec = "HEIC"
        recipe.qualityFloor = options.quality.floor
        recipe.normalized = true

        let before = MediaStats(bytes: inBytes, width: cg.width, height: cg.height)

        // Phase B: engine-backed restore/upscale before encode (opt-in + enhancer present).
        let enhanced = options.enhance != .off && enhancer != nil
        if enhanced, let enhancer {
            cg = try await enhancer.enhance(cg, options: options)
            recipe.restored = true
            switch options.upscale {
            case .none: break
            case .x2: recipe.upscaled = 2
            case .x4: recipe.upscaled = 4
            }
        }

        // GPU-accelerate the quality-target search's SSIMULACRA2 — full-GPU per-channel path (CPU
        // fallback when no Metal device).
        let encoded = try ImageQualityTarget.encodeHEIC(cg, targetScore: options.quality.floor,
                                                        channelScalars: SSIMULACRA2Metal.shared?.channelScalarsFunction)

        // Honest skip applies to the non-enhanced path only — enhance is an explicit opt-in transform.
        guard enhanced || encoded.data.count < inBytes else {
            return OptimizeResult(
                input: url, kind: .image, output: .none, recipe: recipe, before: before,
                after: MediaStats(bytes: inBytes, width: cg.width, height: cg.height,
                                  qualityScore: encoded.score),
                status: .skipped("re-encode (\(encoded.data.count) B) ≥ source (\(inBytes) B)"),
                elapsed: Date().timeIntervalSince(start))
        }

        let output = try write(encoded.data, for: url, ext: "heic", to: destination)
        return OptimizeResult(
            input: url, kind: .image, output: output, recipe: recipe, before: before,
            after: MediaStats(bytes: encoded.data.count, width: cg.width, height: cg.height,
                              qualityScore: encoded.score),
            status: .optimized, elapsed: Date().timeIntervalSince(start), outputType: .heic)
    }

    /// Video path: **target-quality** — smallest HEVC whose per-frame p10 SSIMULACRA2 clears the floor
    /// (GPU-scored), audio passthrough-muxed, colour preserved. Same resolution by default; `options.
    /// resolution = .maxHeight(_)` steps it down (4K→HD), quality measured at the target resolution.
    private func optimizeVideo(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date) async throws -> OptimizeResult {
        let outURL = try resolveVideoOutputURL(for: url, to: destination)
        let r = try await VideoQualityTarget.encode(input: url, output: outURL,
                                                    targetScore: options.quality.floor,
                                                    maxHeight: options.resolution.maxHeight)
        var recipe = AppliedRecipe()
        recipe.codec = "HEVC"
        recipe.normalized = true
        recipe.qualityFloor = options.quality.floor

        let before = MediaStats(bytes: r.inputBytes, width: r.sourceWidth, height: r.sourceHeight)
        let after = MediaStats(bytes: r.outputBytes, width: r.width, height: r.height,
                               qualityScore: r.score)
        // `output` is `.none` unless we actually optimized — the encode leaves NO file at `outURL` on a miss,
        // so the receipt must match (no `.file` pointing at a nonexistent / not-written path → no host orphan).
        let didOptimize = r.metTarget && r.outputBytes < r.inputBytes
        return OptimizeResult(
            input: url, kind: .video, output: didOptimize ? .file(outURL) : .none,
            recipe: recipe, before: before, after: after,
            status: didOptimize ? .optimized
                                : .skipped(r.metTarget ? "not smaller than source"
                                                       : "couldn't reach the SSIMU2 ≥ \(Int(options.quality.floor)) floor"),
            elapsed: Date().timeIntervalSince(start),
            outputType: didOptimize ? .mpeg4Movie : nil)   // HEVC-in-mp4
    }

    // MARK: - Helpers (file + classification)

    func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func mediaKind(of url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ["mkv", "webm"].contains(ext) { return .video }   // UTType mapping is unreliable for these
        guard let ut = UTType(filenameExtension: ext) else { return .unknown }
        if ut.conforms(to: .image) { return .image }
        if ut.conforms(to: .movie) || ut.conforms(to: .audiovisualContent) { return .video }
        return .unknown
    }

    private func prepareDestination(_ destination: Destination) throws {
        switch destination {
        case .directory(let dir):
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        case .fileURL(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        case .alongside, .inMemory:
            break
        }
    }

    private func write(_ data: Data, for input: URL, ext: String,
                       to destination: Destination) throws -> Output {
        switch destination {
        case .inMemory:
            return .data(data)
        case .directory(let dir):
            let out = dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                         .appendingPathExtension(ext)
            try data.write(to: out)
            return .file(out)
        case .alongside(let suffix):
            let stem = input.deletingPathExtension().lastPathComponent + suffix
            let out = input.deletingLastPathComponent().appendingPathComponent(stem)
                         .appendingPathExtension(ext)
            try data.write(to: out)
            return .file(out)
        case .fileURL(let url):                          // host-dictated exact path
            try data.write(to: url)
            return .file(url)
        }
    }

    private func resolveVideoOutputURL(for input: URL, to destination: Destination) throws -> URL {
        switch destination {
        case .directory(let dir):
            return dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                      .appendingPathExtension("mp4")
        case .alongside(let suffix):
            let stem = input.deletingPathExtension().lastPathComponent + suffix
            return input.deletingLastPathComponent().appendingPathComponent(stem)
                        .appendingPathExtension("mp4")
        case .fileURL(let url):                          // host-dictated exact path
            return url
        case .inMemory:
            throw ForgeError.notImplemented("video optimize to .inMemory (Phase A: use a directory)")
        }
    }
}
