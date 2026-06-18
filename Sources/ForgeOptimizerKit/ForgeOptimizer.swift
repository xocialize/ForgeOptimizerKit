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

    public init() {}

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

    private func optimizeOne(_ url: URL, to destination: Destination, _ options: Options,
                             start: Date) async throws -> OptimizeResult {
        switch mediaKind(of: url) {
        case .image: return try optimizeImage(url, to: destination, options, start: start)
        case .video: return try await optimizeVideo(url, to: destination, options, start: start)
        case .unknown: throw ForgeError.unsupportedMedia(url)
        }
    }

    /// Image path: target-quality HEIC via media-bridge's SSIMULACRA2-guided search. The headline.
    private func optimizeImage(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date) throws -> OptimizeResult {
        let inBytes = fileSize(url)
        guard let cg = loadCGImage(url) else { throw ForgeError.decodeFailed(url) }

        let encoded = try ImageQualityTarget.encodeHEIC(cg, targetScore: options.quality.floor)
        var recipe = AppliedRecipe()
        recipe.codec = "HEIC"
        recipe.qualityFloor = options.quality.floor
        recipe.normalized = true

        let before = MediaStats(bytes: inBytes, width: cg.width, height: cg.height)

        // Honest skip: if the target-quality re-encode isn't smaller, keep the original.
        guard encoded.data.count < inBytes else {
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
            status: .optimized, elapsed: Date().timeIntervalSince(start))
    }

    /// Video path (Phase A): normalize → native HEVC mp4. Target-quality (SSIMULACRA2 floor search)
    /// waits on media-bridge's per-frame aggregation — see LESSONS.md.
    private func optimizeVideo(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date) async throws -> OptimizeResult {
        let inBytes = fileSize(url)
        let outURL = try resolveVideoOutputURL(for: url, to: destination)
        let nr = try await MediaBridge.normalizeVideoToHEVC(input: url, output: outURL)
        let outBytes = fileSize(outURL)

        var recipe = AppliedRecipe()
        recipe.codec = "HEVC"
        recipe.normalized = true

        return OptimizeResult(
            input: url, kind: .video, output: .file(outURL), recipe: recipe,
            before: MediaStats(bytes: inBytes, width: nr.width, height: nr.height),
            after: MediaStats(bytes: outBytes, width: nr.width, height: nr.height),
            status: outBytes < inBytes ? .optimized : .skipped("normalized output not smaller"),
            elapsed: Date().timeIntervalSince(start))
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
        if case .directory(let dir) = destination {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        case .inMemory:
            throw ForgeError.notImplemented("video optimize to .inMemory (Phase A: use a directory)")
        }
    }
}
