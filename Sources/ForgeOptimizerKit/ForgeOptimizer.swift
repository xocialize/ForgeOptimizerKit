import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MediaBridge
import ImageBridge
import MediaMeasure
import MediaMetrics

/// The headless ForgeOptimizer core. Phase A runs entirely on media-bridge (pure-Swift, FFmpeg-free):
/// structural `analyze`, target-quality `optimize`, and `.fast` `conform`. No MLX, no metallib —
/// build + test from the CLI. The engine (enhance, perceptual analyze, `.quality` conform) is Phase B.
public struct ForgeOptimizer: Sendable {

    /// Phase-B engine-backed restore/upscale (supplied by the UI/app layer). `nil` = media-bridge-only;
    /// the Kit stays engine-free. Applied before encode when `Options.enhance != .off`.
    private let enhancer: (any ImageEnhancer)?

    /// Phase-B optical-flow seam (SEA-RAFT) for temporally-consistent *video* upscale. `nil` → the video
    /// upscale path runs per-frame SR without flicker stabilization (zero flow).
    private let flowProvider: (any VideoFlowProvider)?

    /// The §6.3 planner-hint seam (VJEPA2 pre-classify) — supplied by the app/ForgeCore layer, like
    /// `enhancer`. `nil` → classical planning only: the class ratchet discovers graphic content from
    /// the first search's own behavior (and pays a second search for it).
    private let hintProvider: (any ContentHintProvider)?

    public init(enhancer: (any ImageEnhancer)? = nil, flowProvider: (any VideoFlowProvider)? = nil,
                hintProvider: (any ContentHintProvider)? = nil,
                bulkConcurrency: Int? = nil) {
        self.enhancer = enhancer
        self.flowProvider = flowProvider
        self.hintProvider = hintProvider
        self.bulkConcurrency = bulkConcurrency
    }

    /// Bulk width for batches of STILLS (videos always run exclusively — one video item already
    /// saturates the encoder and scorer lanes). `nil` → `FORGE_BULK_CONCURRENCY` → 3.
    private let bulkConcurrency: Int?

    /// Effective width, clamped 1…8; an injected enhancer forces 1 (engine memory admission is
    /// the host's budget — revisit after measuring). Default **3**, from the quiet-machine
    /// interleaved A/B (bulkbench, 10× derived-1080 stills, fresh process per arm, spreads <2%):
    /// width 1 = 2.29 s · 2 = 1.37 s (1.68×) · 3 = 1.00 s (2.31×) · 4 = 0.85 s · 6 = 0.65 s
    /// (3.5×). The curve keeps climbing past 3, but each concurrent scorer beyond the cached set
    /// allocates a transient resident-scorer working set (~0.18 GB at 1080p, ~0.75 GB at 4K
    /// stills) — 3 is the conservative library default on unknown machines; hosts that know
    /// their hardware raise the knob (measured 3.5× at 6 on an M5 Max).
    var effectiveBulkWidth: Int {   // internal for the enhancer-forces-serial test
        guard enhancer == nil else { return 1 }
        let raw = bulkConcurrency
            ?? ProcessInfo.processInfo.environment["FORGE_BULK_CONCURRENCY"].flatMap(Int.init)
            ?? 3
        return min(max(raw, 1), 8)
    }

    // MARK: - analyze (read-only)

    /// Probe + verify + recommend, without writing anything. **Every input yields an `Analysis`** —
    /// a file that can't be probed no longer vanishes from the stream; its integrity report says
    /// what is wrong with it (production corruption surfaces as data, not as absence).
    /// `Options.integrity` picks the verification tier: `.structural` byte walks by default,
    /// `.deep` adds a decode-to-EOF pass.
    public func analyze(_ source: Source, _ options: Options = .init()) -> AsyncStream<Analysis> {
        let urls = source.urls
        return AsyncStream { continuation in
            Task {
                for url in urls {
                    continuation.yield(await analyzeOne(url, options))
                }
                continuation.finish()
            }
        }
    }

    private func analyzeOne(_ url: URL, _ options: Options) async -> Analysis {
        let bytes = fileSize(url)

        // Integrity first — its walks are magic-byte-routed, so they also cover mislabeled files
        // the kind classifier (extension-based) gets wrong.
        let bridge = await MediaIntegrity.verify(
            url: url, level: options.integrity == .deep ? .deep : .structural)
        var checks = bridge.checks.map {
            IntegrityCheck(name: $0.name, outcome: .init(bridge: $0.outcome), detail: $0.detail)
        }
        var verdict = IntegrityReport.Verdict(bridge: bridge.verdict)
        let kind = mediaKind(of: url)

        switch kind {
        case .image:
            if let meta = try? ImageBridgeFactory.makeProbe().probe(url: url) {
                if meta.width > 0 && meta.height > 0 {
                    checks.append(IntegrityCheck(name: "probe-sanity", outcome: .passed))
                } else {
                    checks.append(IntegrityCheck(name: "probe-sanity", outcome: .failed,
                                                 detail: "probed dimensions \(meta.width)×\(meta.height)"))
                    verdict.escalate(to: .suspect)
                }
                var recipe = AppliedRecipe()
                // The recommendation reflects an explicit still pin; `.auto` (and the video-only
                // `.hevc`) keep the native default. analyze is read-only, so invalid pairings
                // aren't policed here — optimize is where they fail.
                switch Self.stillPin(options.output) ?? .heic {
                case .heic:
                    recipe.codec = "HEIC"
                    recipe.qualityFloor = options.quality.floor
                    recipe.normalized = meta.format != .heic
                case .jpeg:
                    recipe.codec = "JPEG"
                    recipe.qualityFloor = options.quality.floor
                    recipe.normalized = meta.format != .jpeg
                case .png:
                    recipe.codec = "PNG"                        // lossless: no floor to carry
                    recipe.normalized = meta.format != .png
                }
                let estimate = SavingsEstimate(
                    estimatedFraction: nil,
                    note: recipe.qualityFloor.map {
                        "run optimize for actual savings (target SSIMULACRA2 ≥ \(Int($0)))"
                    } ?? "run optimize for actual savings (lossless PNG, measured round-trip)")
                return Analysis(input: url, kind: .image, width: meta.width, height: meta.height,
                                bytes: bytes, codecID: meta.format.rawValue, qualityScore: nil,
                                recommendation: recipe, estimate: estimate,
                                integrity: IntegrityReport(verdict: verdict, checks: checks))
            }
            return unprobeable(url, kind: kind, bytes: bytes, verdict: &verdict, checks: &checks)

        case .video:
            if let info = try? await MediaBridge.probe(url: url) {
                let v = info.videoStreams.first
                var sanity: [String] = []
                if v == nil { sanity.append("no video stream") }
                if let v, v.width <= 0 || v.height <= 0 {
                    sanity.append("probed dimensions \(v.width)×\(v.height)")
                }
                if info.durationSeconds <= 0 { sanity.append("zero duration") }
                // A "video" whose whole file implies < 8 kbps is structurally implausible — the
                // classic symptom of a metadata shell around missing payload.
                if info.durationSeconds >= 1, bytes > 0,
                   Double(bytes) * 8 / info.durationSeconds < 8_000 {
                    sanity.append(String(format: "implied bitrate %.1f kbps is implausible",
                                         Double(bytes) * 8 / info.durationSeconds / 1000))
                }
                if sanity.isEmpty {
                    checks.append(IntegrityCheck(name: "probe-sanity", outcome: .passed))
                } else {
                    checks.append(IntegrityCheck(name: "probe-sanity", outcome: .failed,
                                                 detail: sanity.joined(separator: "; ")))
                    verdict.escalate(to: .suspect)
                }
                // The planning verb must not recommend what the executing verb refuses: same
                // probe, same predicate as `optimizeVideo`'s alpha refusal. `passthrough` +
                // a "not optimizable" note is the shape `unprobeable` already uses.
                if let v, Self.refusesAlpha(v) {
                    return Analysis(input: url, kind: .video, width: v.width, height: v.height,
                                    bytes: bytes, codecID: v.codecID, qualityScore: nil,
                                    recommendation: AppliedRecipe(),
                                    estimate: SavingsEstimate(
                                        estimatedFraction: nil,
                                        note: "not optimizable: " + Self.alphaRefusalReason),
                                    integrity: IntegrityReport(verdict: verdict, checks: checks))
                }
                var recipe = AppliedRecipe()
                recipe.codec = "HEVC"
                recipe.normalized = !info.container.isNativeApple
                let estimate = SavingsEstimate(
                    estimatedFraction: nil,
                    note: "video target-quality pending per-frame aggregation; optimize = normalize")
                return Analysis(input: url, kind: .video, width: v?.width ?? 0, height: v?.height ?? 0,
                                bytes: bytes, codecID: v?.codecID ?? "?", qualityScore: nil,
                                recommendation: recipe, estimate: estimate,
                                integrity: IntegrityReport(verdict: verdict, checks: checks))
            }
            return unprobeable(url, kind: kind, bytes: bytes, verdict: &verdict, checks: &checks)

        case .unknown:
            return unprobeable(url, kind: kind, bytes: bytes, verdict: &verdict, checks: &checks)
        }
    }

    /// The diagnostic `Analysis` for a file the probe cannot read (or an unknown kind): the
    /// integrity walk usually explains *why*, and a byte-clean file the probe still rejects is
    /// exactly the "usable with eyes open" case `suspect` exists for.
    private func unprobeable(_ url: URL, kind: MediaKind, bytes: Int,
                             verdict: inout IntegrityReport.Verdict,
                             checks: inout [IntegrityCheck]) -> Analysis {
        if kind != .unknown {
            checks.append(IntegrityCheck(name: "probe", outcome: .failed,
                                         detail: "media probe cannot read this file"))
            verdict.escalate(to: .suspect)
        }
        let report = IntegrityReport(verdict: verdict, checks: checks)
        return Analysis(input: url, kind: kind, width: 0, height: 0, bytes: bytes, codecID: "?",
                        qualityScore: nil, recommendation: AppliedRecipe(),
                        estimate: SavingsEstimate(estimatedFraction: nil,
                                                  note: "not optimizable: \(report.summary)"),
                        integrity: report)
    }

    // MARK: - optimize

    /// Which deliverable family `optimize` targets. `.native` is the opinionated Apple set (HEIC
    /// stills, HEVC-in-mp4 video); `.web` is the universal set every browser decodes (PNG stills,
    /// H.264 + AAC mp4). Internal: the public surface is the verb pair `optimize` / `webOptimize`.
    enum OutputProfile: Sendable { case native, web }

    /// Stream a receipt per input. Per-item failures are isolated (yielded as `.failed`), so one bad
    /// file never aborts a bulk run. Throws only on up-front contract errors (e.g. unwritable folder).
    public func optimize(_ source: Source, to destination: Destination,
                         _ options: Options = .init(),
                         progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        throws -> AsyncStream<OptimizeResult> {
        try stream(source, to: destination, options, profile: .native, progress: progress)
    }

    /// `optimize` for web platforms: same planner, same receipts, web-universal outputs — stills →
    /// **PNG** (lossless, so visually identical by definition; the measured round-trip score is on
    /// the receipt), video → **H.264 + AAC in mp4** (the one combination every browser plays).
    ///
    /// **A non-web-native input always converts.** Larger than the source is fine, a floor miss
    /// delivers the best-effort ceiling encode (the receipt carries the honest shortfall against
    /// `Options.quality`), and a container AVFoundation can't re-encode (MKV/WebM) is automatically
    /// normalized through media-bridge's pure-Swift path first. The honest skip survives only where
    /// the input is already web-native (PNG / H.264-mp4+AAC) and the re-encode isn't smaller —
    /// there the original itself is the web deliverable.
    public func webOptimize(_ source: Source, to destination: Destination,
                            _ options: Options = .init(),
                            progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        throws -> AsyncStream<OptimizeResult> {
        try stream(source, to: destination, options, profile: .web, progress: progress)
    }

    private func stream(_ source: Source, to destination: Destination, _ options: Options,
                        profile: OutputProfile,
                        progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        throws -> AsyncStream<OptimizeResult> {
        try prepareDestination(destination)
        let urls = source.urls
        return AsyncStream { continuation in
            Task {
                let itemCount = urls.count
                // One body for both schedules: emits, span, and failure isolation are per-item
                // and identical either way. (Vs the historical serial loop, the finalizing emit
                // now precedes the yield — receipts are unchanged and progress consumers treat
                // finalizing as item-done.)
                @Sendable func processItem(_ i: Int, _ url: URL) async -> OptimizeResult {
                    let start = Date()
                    let mmItem = MediaMetrics.begin("kit.item", lane: "kit",
                                                    attrs: ["input": url.lastPathComponent,
                                                            "index": "\(i)"])
                    defer { MediaMetrics.end(mmItem) }
                    let emit: ProgressEmit? = progress.map { handler in
                        { phase, fraction, detail in
                            handler(OptimizeProgress(context: nil, input: url, phase: phase,
                                                     fraction: fraction, detail: detail,
                                                     itemIndex: i, itemCount: itemCount))
                        }
                    }
                    emit?(.searching, 0, nil)
                    defer { emit?(.finalizing, 1, nil) }
                    do {
                        return try await optimizeOne(url, to: destination, options,
                                                     start: start, profile: profile, emit: emit)
                    } catch {
                        let bytes = fileSize(url)
                        return OptimizeResult(
                            input: url, kind: mediaKind(of: url), output: .none, recipe: AppliedRecipe(),
                            before: MediaStats(bytes: bytes, width: 0, height: 0),
                            after: MediaStats(bytes: bytes, width: 0, height: 0),
                            status: .failed("\(error)"), elapsed: Date().timeIntervalSince(start))
                    }
                }
                let width = effectiveBulkWidth
                if width > 1 {
                    await runBulk(urls, width: width,
                                  isStill: { mediaKind(of: $0) == .image },
                                  process: processItem,
                                  yield: { continuation.yield($0) })
                } else {
                    for (i, url) in urls.enumerated() {
                        continuation.yield(await processItem(i, url))
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Pipeline entry: each `OptimizeRequest` names its **exact output URL** and an optional `context`
    /// token (echoed on the result). Per-item failures are isolated. `progress` carries batch indices
    /// plus coarse per-item stages today (see `OptimizeProgress` — per-pass fractions arrive with the
    /// media-bridge 0.28.0 adoption). Single-flight + busy-rejection live in `ForgeOptimizerService`,
    /// not here.
    public func optimize(_ requests: [OptimizeRequest],
                         progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        -> AsyncStream<OptimizeResult> {
        run(requests, progress: progress, profile: .native)
    }

    /// Pipeline form of `webOptimize` — the host-dictated-URL seam, web-universal outputs. Name the
    /// output URLs `.png` / `.mp4`; `outputType` on the receipt stays the authoritative type either way.
    public func webOptimize(_ requests: [OptimizeRequest],
                            progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        -> AsyncStream<OptimizeResult> {
        run(requests, progress: progress, profile: .web)
    }

    private func run(_ requests: [OptimizeRequest],
                     progress: (@Sendable (OptimizeProgress) -> Void)?,
                     profile: OutputProfile)
        -> AsyncStream<OptimizeResult> {
        AsyncStream { continuation in
            Task {
                let itemCount = requests.count
                @Sendable func processItem(_ i: Int, _ req: OptimizeRequest) async -> OptimizeResult {
                    let start = Date()
                    let mmItem = MediaMetrics.begin("kit.item", lane: "kit",
                                                    attrs: ["input": req.input.lastPathComponent,
                                                            "index": "\(i)"])
                    defer { MediaMetrics.end(mmItem) }
                    let emit: ProgressEmit? = progress.map { handler in
                        { phase, fraction, detail in
                            handler(OptimizeProgress(context: req.context, input: req.input,
                                                     phase: phase, fraction: fraction, detail: detail,
                                                     itemIndex: i, itemCount: itemCount))
                        }
                    }
                    emit?(.searching, 0, nil)
                    defer { emit?(.finalizing, 1, nil) }
                    do {
                        try prepareDestination(.fileURL(req.output))
                        let r = try await optimizeOne(req.input, to: .fileURL(req.output), req.options,
                                                      start: start, profile: profile, emit: emit)
                        return r.with(context: req.context)
                    } catch {
                        let bytes = fileSize(req.input)
                        return OptimizeResult(
                            input: req.input, kind: mediaKind(of: req.input), output: .none,
                            recipe: AppliedRecipe(), before: MediaStats(bytes: bytes, width: 0, height: 0),
                            after: MediaStats(bytes: bytes, width: 0, height: 0),
                            status: .failed("\(error)"), elapsed: Date().timeIntervalSince(start),
                            context: req.context)
                    }
                }
                let width = effectiveBulkWidth
                if width > 1 {
                    await runBulk(requests, width: width,
                                  isStill: { mediaKind(of: $0.input) == .image },
                                  process: processItem,
                                  yield: { continuation.yield($0) })
                } else {
                    for (i, req) in requests.enumerated() {
                        continuation.yield(await processItem(i, req))
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Per-item progress emitter, already bound to the item's context/input/batch position by the
    /// caller: (phase, fraction within this item, optional human detail line).
    typealias ProgressEmit = @Sendable (OptimizeProgress.Phase, Double, String?) -> Void

    /// Ordered, width-bounded bulk executor (opt-in via `effectiveBulkWidth`). Consecutive STILLS
    /// process concurrently up to `width`; any non-still runs exclusively (one video item already
    /// saturates the encoder + scorer lanes; unknowns take the safe path and fail in isolation).
    /// Results yield strictly in **submission order** — completions buffer until their turn — and
    /// the buffer/next-yield state lives on the calling task only, so the drain is race-free by
    /// construction. Failure isolation is `process`'s own (identical to the serial loop's body).
    private func runBulk<Item: Sendable>(
        _ items: [Item], width: Int,
        isStill: (Item) -> Bool,
        process: @escaping @Sendable (Int, Item) async -> OptimizeResult,
        yield: (OptimizeResult) -> Void) async {
        var i = 0
        while i < items.count {
            guard isStill(items[i]) else {
                yield(await process(i, items[i]))
                i += 1
                continue
            }
            var run: [(index: Int, item: Item)] = []
            while i < items.count, isStill(items[i]) {
                run.append((i, items[i]))
                i += 1
            }
            var buffer: [Int: OptimizeResult] = [:]
            var nextYield = run[0].index
            await withTaskGroup(of: (Int, OptimizeResult).self) { group in
                var submitted = 0
                for (index, item) in run {
                    if submitted >= width, let (di, r) = await group.next() {
                        buffer[di] = r
                        while let ready = buffer.removeValue(forKey: nextYield) {
                            yield(ready)
                            nextYield += 1
                        }
                    }
                    group.addTask { (index, await process(index, item)) }
                    submitted += 1
                }
                for await (di, r) in group {
                    buffer[di] = r
                    while let ready = buffer.removeValue(forKey: nextYield) {
                        yield(ready)
                        nextYield += 1
                    }
                }
            }
        }
    }

    /// The deep-progress seam: maps media-bridge's pass-granular `SearchProgress` into this item's
    /// emitter. `base`/`span` place the search inside the item's own 0…1 (the first search spans
    /// 0.05…0.95; the class-ratchet re-run re-opens at 0.50). Returns nil when the caller isn't
    /// listening, so the search skips the callback entirely.
    private static func searchProgressAdapter(emit: ProgressEmit?, base: Double, span: Double)
        -> (@Sendable (VideoQualityTarget.SearchProgress) -> Void)? {
        guard let emit else { return nil }
        return { p in
            let f = base + span * p.fraction
            switch p.stage {
            case .preparing:
                emit(.searching, f, nil)
            case .mezzanine(let toneMapSDR, let downscale):
                var what: [String] = []
                if downscale { what.append("downscale") }
                if toneMapSDR { what.append("HDR→SDR tone-map") }
                emit(.encoding, f, "Rendering near-lossless reference"
                     + (what.isEmpty ? "" : " — " + what.joined(separator: " + ")))
            case .pass(let label, let index, let planned, let bitrate):
                emit(.encoding, f, String(format: "pass %d/%d (%@) · encoding at %.1f Mbps",
                                          index, planned, label, Double(bitrate) / 1e6))
            case .scoring(let label, let index, let planned):
                emit(.scoring, f, "pass \(index)/\(planned) (\(label)) · scoring per-frame SSIMULACRA2")
            case .passResult(let label, let p10, let cleared, let bestBitrate, let bestP10):
                var line = String(format: "%@ · p10 %.1f · %@", label, p10,
                                  cleared ? "clears the floor" : "below the floor")
                if let bb = bestBitrate, let bp = bestP10 {
                    line += String(format: " · best %.1f Mbps (p10 %.1f)", Double(bb) / 1e6, bp)
                }
                emit(.scoring, f, line)
            case .finalizing:
                emit(.finalizing, f, nil)
            }
        }
    }

    private func optimizeOne(_ url: URL, to destination: Destination, _ options: Options,
                             start: Date, profile: OutputProfile = .native,
                             emit: ProgressEmit? = nil) async throws -> OptimizeResult {
        let kind = mediaKind(of: url)
        try Self.validate(options.output, for: kind, profile: profile)
        switch kind {
        case .image: return try await optimizeImage(url, to: destination, options, start: start,
                                                    profile: profile, emit: emit)
        case .video: return try await optimizeVideo(url, to: destination, options, start: start,
                                                    profile: profile, emit: emit)
        case .unknown: throw ForgeError.unsupportedMedia(url)
        }
    }

    /// `Options.output` × media kind × verb, checked before any decode runs. Invalid pairings fail
    /// the item (isolated in a bulk run like any per-item failure) — never silently reinterpreted.
    private static func validate(_ output: OutputFormat, for kind: MediaKind,
                                 profile: OutputProfile) throws {
        switch (kind, output) {
        case (_, .auto), (.unknown, _):
            return                              // unknown kind throws unsupportedMedia right after
        case (.image, .hevc):
            throw ForgeError.invalidOptions("HEVC is the video codec — stills take .heic, .jpeg, or .png")
        case (.image, .heic) where profile == .web:
            throw ForgeError.invalidOptions(
                "HEIC is not web-universal — webOptimize stills race PNG/JPEG (use optimize for HEIC)")
        case (.image, _):
            return
        case (.video, .hevc):
            guard profile == .native else {
                throw ForgeError.invalidOptions(
                    "webOptimize video is H.264+AAC by contract — use optimize for HEVC")
            }
            return
        case (.video, _):
            throw ForgeError.invalidOptions(
                "\(output) is a stills format — video writes HEVC (optimize) / H.264 (webOptimize)")
        }
    }

    /// Image path: optional engine enhance → target-quality HEIC via media-bridge's SSIMULACRA2
    /// search (`.native`), or lossless PNG with the measured round-trip score (`.web`). An explicit
    /// `Options.output` still pin reroutes the encode (conversion semantics — see `OutputFormat`).
    private func optimizeImage(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date, profile: OutputProfile,
                               emit: ProgressEmit? = nil) async throws -> OptimizeResult {
        let requested = Self.stillPin(options.output)
        // An ANIMATED GIF is motion content wearing a still extension: on the web profile it
        // converts to an H.264 mp4 (typically ~10× smaller) through the same floor search as any
        // video. Single-frame GIFs fall through to the still race like every other image.
        if profile == .web, isGIF(url), GIFVideo.frameCount(url) > 1 {
            // Motion content can't honour a stills pin, and pinning the first frame would silently
            // drop the animation — refused, not reinterpreted.
            guard requested == nil else {
                throw ForgeError.invalidOptions(
                    "an animated GIF converts to web video (mp4) — a stills format pin does not apply")
            }
            emit?(.searching, 0.05,
                  "Converting animated GIF — compositing frames, then searching for the smallest "
                  + "H.264 that clears SSIMULACRA2 ≥ \(Int(options.quality.floor))")
            return try await optimizeAnimatedGIF(url, to: destination, options, start: start)
        }
        let inBytes = fileSize(url)
        // Orientation is baked at decode (branch) INSIDE the decode span (main): a rotated source
        // must not ship sideways, and the stage still has to show up in the timeline.
        let still = MediaMetrics.time("kit.decode", lane: "decode",
                                      attrs: ["input": url.lastPathComponent]) { Self.loadOrientedStill(url) }
        guard let still else { throw ForgeError.decodeFailed(url) }
        var cg = still.image

        var recipe = AppliedRecipe()
        recipe.normalized = true

        let before = MediaStats(bytes: inBytes, width: cg.width, height: cg.height)

        // Phase B: engine-backed restore/upscale before encode (opt-in + enhancer present).
        let enhanced = options.enhance != .off && enhancer != nil
        if enhanced, let enhancer {
            let widthBefore = cg.width
            cg = try await MediaMetrics.time("kit.enhance", lane: "gpu",
                                             attrs: ["w": "\(cg.width)", "h": "\(cg.height)"]) {
                try await enhancer.enhance(cg, options: options)
            }
            recipe.restored = true
            // Measured, not requested (BRIDGE-062). The enhance seam returns only a CGImage, so the
            // artifact is the only thing that can be trusted about what happened to it.
            recipe.setUpscale(measuredFrom: widthBefore, to: cg.width, requested: options.upscale)
        }

        // A host-dictated URL that NAMES a still format pins it — the host baked the path
        // (e.g. `entity-7--web.png`) and racing to a different codec would write mislabeled
        // bytes into it. The race runs only when the destination doesn't name a format.
        let pinnedExt: String? = {
            if case .fileURL(let u) = destination {
                let e = u.pathExtension.lowercased()
                if ["png", "jpg", "jpeg"].contains(e) { return e }
            }
            return nil
        }()

        // Options pin vs host pin: both are explicit; a contradiction is refused, not arbitrated.
        if let requested, let pinnedExt {
            let matches = (requested == .png && pinnedExt == "png")
                || (requested == .jpeg && (pinnedExt == "jpg" || pinnedExt == "jpeg"))
            guard matches else {
                throw ForgeError.invalidOptions(
                    "output format \(requested.rawValue) conflicts with the host-pinned '.\(pinnedExt)' destination")
            }
        }
        // The host-pinned extension counts as a pin only where it is honoured — the web race. The
        // native deliverable is HEIC whatever the path says (see `Destination.fileURL`).
        let hostPin: StillFormat? = profile == .web
            ? (pinnedExt == "png" ? .png : pinnedExt != nil ? .jpeg : nil)
            : nil
        let pin: StillFormat? = requested ?? hostPin
        // JPEG has no alpha. The race's transparency gate quietly routes implicit paths to PNG;
        // an EXPLICIT .jpeg — `Options.output` or a host-pinned `.jpg` path — on a transparent
        // image gets a refusal instead: shipping PNG bytes into a `.jpg` path and compositing the
        // alpha away are both silent reinterpretations.
        if pin == .jpeg, Self.hasRealTransparency(cg) {
            throw ForgeError.invalidOptions(
                requested == .jpeg
                    ? "JPEG cannot represent transparency and this image has transparent pixels — use .png or .heic"
                    : "JPEG cannot represent transparency and this image has transparent pixels — the "
                      + "host-pinned '.\(pinnedExt ?? "jpg")' destination cannot hold it; pin .png or "
                      + "pass an extension-less path")
        }

        // GPU-accelerate the SSIMULACRA2 — full-GPU per-channel path (CPU fallback when no Metal device).
        let scalars = SSIMULACRA2Metal.shared?.channelScalarsFunction
        var data: Data
        let score: Double
        let outExt: String
        let outType: UTType
        switch profile {
        case .native:
            // Native deliverable: HEIC by default; an explicit pin reroutes the same machinery
            // (floor search for the lossy formats, measured round-trip for lossless PNG).
            switch requested ?? .heic {
            case .heic:
                let encoded = try await ImageQualityTarget.encodeHEIC(cg, targetScore: options.quality.floor,
                                                                      channelScalars: scalars)
                data = encoded.data; score = encoded.score
                recipe.codec = "HEIC"
                recipe.qualityFloor = options.quality.floor
                outExt = "heic"; outType = .heic
            case .jpeg:
                let encoded = try await ImageQualityTarget.encodeJPEG(cg, targetScore: options.quality.floor,
                                                                      channelScalars: scalars)
                data = encoded.data; score = encoded.score
                recipe.codec = "JPEG"
                recipe.qualityFloor = options.quality.floor
                outExt = "jpg"; outType = .jpeg
            case .png:
                let encoded = try await ImageQualityTarget.encodePNG(cg, channelScalars: scalars)
                data = encoded.data; score = encoded.score
                recipe.codec = "PNG"
                recipe.qualityFloor = nil                       // PNG has no floor: lossless
                outExt = "png"; outType = .png
            }
        case .web:
            // The web still is a RACE, not a classification: the lossless PNG always runs; a JPEG
            // floor search runs alongside unless the image carries alpha (JPEG has none). Ship the
            // smaller deliverable that keeps its guarantee — photos land 5–10× under PNG via JPEG,
            // flat graphics ring + inflate under JPEG and PNG wins on size, transparency is PNG by
            // construction. No content classifier to mis-tune; the outcome decides.
            // An explicit `Options.output` pin folds in exactly like a host-pinned URL: it benches
            // the other lane rather than changing the mechanics (`pin` resolves both, above).
            let png = try await ImageQualityTarget.encodePNG(cg, channelScalars: scalars)
            // Gate on TRUE transparency, not channel presence: opaque-RGBA is everywhere in
            // consumer content (screenshots, decoded video frames, editor exports), and treating
            // the mere existence of an alpha channel as transparency silently benched the JPEG
            // race on exactly the photos it exists for (a real 6 MP frame shipped 2.3 MB PNG
            // where JPEG@floor measured 0.5 MB — caught by the skip receipt, 2026-08-09).
            var jpeg: ImageQualityTarget.Result?
            if pin != .png, !Self.hasRealTransparency(cg) {
                jpeg = try await ImageQualityTarget.encodeJPEG(cg, targetScore: options.quality.floor,
                                                               channelScalars: scalars)
            }
            if let jpeg, pin == .jpeg || (jpeg.metTarget && jpeg.data.count < png.data.count) {
                data = jpeg.data; score = jpeg.score
                recipe.codec = "JPEG"
                recipe.qualityFloor = options.quality.floor
                outExt = "jpg"; outType = .jpeg
            } else {
                data = png.data; score = png.score
                recipe.codec = "PNG"
                recipe.qualityFloor = nil                       // PNG has no floor: lossless
                outExt = "png"; outType = .png
            }
        }

        // `stripMetadata` honored — both modes are real now. `true` ships exactly the fresh encode,
        // metadata-clean by construction; `false` (the declared default) carries the source's
        // metadata into the deliverable losslessly (the compressed payload is untouched).
        // Orientation is excluded either way: it was baked into pixels at decode, and a carried
        // tag would rotate the output a second time.
        if !options.stripMetadata, let metadata = still.metadata {
            data = Self.injectingMetadata(metadata, into: data, type: outType) ?? data
        }

        // Honest skip applies to the non-enhanced path only — enhance is an explicit opt-in transform.
        // Native: skip whenever the re-encode isn't smaller. Web: skip only when the input is
        // already web-native (PNG or JPEG) — the original itself is a valid web deliverable and a
        // bigger re-encode would be a strict loss — EXCEPT when a host-pinned URL or an explicit
        // `Options.output` requests a DIFFERENT format than the source's: that is a format
        // conversion, and a conversion delivers even when larger (the same semantics the video
        // path gives non-web-native sources). A strip on a source that carries metadata also
        // delivers regardless of size: the skip would keep the original, and the original's
        // metadata is exactly what the caller asked to shed.
        let sourceFormat = probedStillFormat(url)
        let webNativeFormat: String? = profile == .web
            ? (sourceFormat == .png || sourceFormat == .jpeg ? sourceFormat?.rawValue : nil)
            : nil
        let pinnedMatchesSource = pinnedExt == nil
            || (pinnedExt == "png" && webNativeFormat == "PNG")
            || ((pinnedExt == "jpg" || pinnedExt == "jpeg") && webNativeFormat == "JPEG")
        let optionsConversion = requested != nil && requested != sourceFormat
        let stripDelivers = options.stripMetadata && still.metadata != nil
        let sizeGated = !optionsConversion && !stripDelivers
            && (profile == .native || (webNativeFormat != nil && pinnedMatchesSource))
        guard enhanced || !sizeGated || data.count < inBytes else {
            let why = profile == .web
                ? "already web-ready (\(webNativeFormat ?? "web still")); re-encode (\(data.count) B) ≥ source (\(inBytes) B)"
                : "re-encode (\(data.count) B) ≥ source (\(inBytes) B)"
            return OptimizeResult(
                input: url, kind: .image, output: .none, recipe: recipe, before: before,
                after: MediaStats(bytes: inBytes, width: cg.width, height: cg.height,
                                  qualityScore: score),
                status: .skipped(why),
                elapsed: Date().timeIntervalSince(start))
        }

        // The strip claim rides only on a DELIVERY — a skip keeps the original, and a receipt
        // claiming a strip that shipped nothing would be the receipt lying. (A skip under
        // `stripMetadata` can only happen on a metadata-free source; `stripDelivers` forces
        // delivery otherwise.)
        recipe.strippedMetadata = options.stripMetadata
        let output = try MediaMetrics.time("kit.write", lane: "io") {
            try write(data, for: url, ext: outExt, to: destination)
        }
        return OptimizeResult(
            input: url, kind: .image, output: output, recipe: recipe, before: before,
            after: MediaStats(bytes: data.count, width: cg.width, height: cg.height,
                              qualityScore: score),
            status: .optimized, elapsed: Date().timeIntervalSince(start),
            outputType: outType)
    }

    /// The input's *actual* still format is PNG (probed, not extension-guessed). Unprobeable inputs
    /// count as not-PNG: the conversion then delivers, which is the safe direction for a web verb.
    /// The animated-GIF → web-mp4 conversion: GIFVideo renders the near-lossless mezzanine
    /// (per-frame timing, white-composited), and the standard webH264 floor search produces the
    /// deliverable — conversion semantics (best-effort, delivers even when larger; a GIF is never
    /// web-native video). The receipt reads like any video normalize; the output name/extension
    /// follow the video rules (.mp4).
    private func optimizeAnimatedGIF(_ url: URL, to destination: Destination, _ options: Options,
                                     start: Date) async throws -> OptimizeResult {
        let sourceBytes = fileSize(url)
        // Transparency composites over WHITE on this route (the mezzanine's web-background
        // convention; a `<video>` has no alpha either). It is the one place the Kit knowingly
        // flattens — the alpha-VIDEO rule is a refusal — so the receipt must say so: the flatten
        // is invisible in the bytes and to the scorer. Frame 0 is the right sample; later delta
        // frames use transparent pixels as "unchanged" markers, not visible alpha.
        let flattened: Bool = {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
            return Self.hasRealTransparency(first)
        }()
        let mezz = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-gif-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: mezz) }
        _ = try await GIFVideo.renderMezzanine(input: url, output: mezz)

        let outURL = try resolveVideoOutputURL(for: url, to: destination)
        let r = try await VideoQualityTarget.encode(input: mezz, output: outURL,
                                                    targetScore: options.quality.floor,
                                                    maxHeight: options.resolution.maxHeight ?? options.quality.impliedMaxHeight,
                                                    profile: .webH264)
        var recipe = AppliedRecipe()
        recipe.codec = "H.264"
        recipe.normalized = true
        // Writer-clean encode: the strip guarantee holds — claimed on deliveries only.
        recipe.strippedMetadata = options.stripMetadata && r.delivered
        recipe.qualityFloor = options.quality.floor
        recipe.flattenedAlpha = flattened && r.delivered   // a skip keeps the transparent original
        let before = MediaStats(bytes: sourceBytes, width: r.sourceWidth, height: r.sourceHeight)
        let after = MediaStats(bytes: r.delivered ? r.outputBytes : sourceBytes,
                               width: r.width, height: r.height,
                               qualityScore: r.score,
                               qualityAggregation: .init(percentile: r.aggregation.percentile,
                                                         minimum: r.aggregation.minimum,
                                                         mean: r.aggregation.mean,
                                                         framesScored: r.aggregation.framesScored,
                                                         frameCount: r.aggregation.frameCount))
        return OptimizeResult(
            input: url, kind: .video, output: r.delivered ? .file(outURL) : .none,
            recipe: recipe, before: before, after: after,
            status: r.delivered ? .optimized
                                : .skipped("couldn't produce the GIF→mp4 deliverable"),
            elapsed: Date().timeIntervalSince(start),
            outputType: r.delivered ? .mpeg4Movie : nil)
    }

    private func isGIF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .gif) == true
    }

    /// Whether the consumer preset's camera-noise self-gate may run for this request. The
    /// rationale (why rendered content must be able to opt out, the AB-A-0055 measurement) lives
    /// on `CameraGate`; this is the mechanism.
    ///
    /// Two suppressions: `.off` states the POLICY; an explicit `.graphic` class states the CONTENT
    /// (rendered / vector / text is definitionally not camera capture). `.general` deliberately
    /// does NOT suppress — it means "everything else", which INCLUDES handheld footage, the exact
    /// content the gate exists for. (The one place a declared class is asymmetric: it silences the
    /// §6.3 hint for BOTH values because a hint estimates the very axis the caller stated; the gate
    /// measures a different axis, so only the value that settles that axis silences it.)
    ///
    /// Suppression rather than a tie-break because the gate is the planner's only floor-LOWERING
    /// device and it runs ahead of the floor chain: a fired gate used to outrank an explicit
    /// `.graphic` and take its floor from 90 to 70, softening in the reference itself exactly the
    /// text edges that class exists to protect — while `Options.contentClass` is documented as
    /// able to "strengthen the promise, never weaken it".
    static func cameraGateAllowed(_ options: Options) -> Bool {
        options.cameraGate == .auto && options.contentClass != .graphic
    }

    /// The alpha-refusal predicate `optimizeVideo` and `analyze` share, so the planning verb never
    /// recommends what the executing verb declines. Declaration-level by design (media-bridge's
    /// `hasAlpha` reads the format description, never pixels): refusing an opaque-but-tagged plane
    /// costs a skip, flattening a real one costs a wrong file. A stream this Kit cannot decode is
    /// left to the codec path — its honest failure names the real blocker, not alpha.
    static func refusesAlpha(_ stream: VideoStreamInfo) -> Bool {
        stream.hasAlpha && stream.nativelyDecodable
    }

    static let alphaRefusalReason = "alpha content — the mp4 deliverable cannot carry an alpha "
        + "channel and flattening it would be silent; original kept"

    /// The one wording for a floor miss, fed the floor the search actually held — every video
    /// skip path formats it from the same number the receipt's `qualityFloor` carries, so the
    /// text cannot cite a bar nothing was measured against.
    static func floorMissReason(_ floor: Double) -> String {
        "couldn't reach the SSIMU2 ≥ \(Int(floor)) floor"
    }

    /// Whether any pixel actually USES the alpha channel (< 255). Channel PRESENCE is not
    /// transparency — opaque-RGBA must not disqualify JPEG. Full-res alpha-only render + scan;
    /// single-digit milliseconds at 6 MP, early-exits on the first transparent pixel.
    static func hasRealTransparency(_ image: CGImage) -> Bool {
        guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        else { return false }
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return true }    // cannot inspect → assume transparency (PNG is the safe format)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        let rowBytes = ctx.bytesPerRow
        for y in 0..<h {
            let row = base + y * rowBytes
            for x in 0..<w where row[x] != 255 { return true }
        }
        return false
    }

    /// The still-format routing vocabulary an `Options.output` pin (or a probed source) resolves to.
    enum StillFormat: String { case heic = "HEIC", jpeg = "JPEG", png = "PNG" }

    /// The still format an explicit `Options.output` names — nil for `.auto` (and `.hevc`, which
    /// validation keeps off the image path).
    private static func stillPin(_ output: OutputFormat) -> StillFormat? {
        switch output {
        case .auto, .hevc: return nil
        case .heic: return .heic
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }

    /// The source's ACTUAL still format (probed, not extension-guessed) — nil when it isn't one of
    /// the three routing formats or can't be probed. Feeds the conversion-vs-optimization decision
    /// and the web honest-skip gate.
    private func probedStillFormat(_ url: URL) -> StillFormat? {
        switch (try? ImageBridgeFactory.makeProbe().probe(url: url))?.format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        default: return nil
        }
    }

    /// Video path: **target-quality** — smallest encode whose per-frame p10 SSIMULACRA2 clears the
    /// floor (GPU-scored), colour preserved. `.native` → HEVC, audio passthrough-muxed; `.web` →
    /// H.264 + AAC (the mp4 every browser plays), delivered even when larger unless the source is
    /// already web-native. Same resolution by default; `options.resolution = .maxHeight(_)` steps it
    /// down (4K→HD), quality measured at the target resolution.
    /// One human line per `SearchProgress` event — the "Pass 3/6 — encoding at 8.2 Mbps" /
    /// "best so far 7.4 Mbps @ p10 81.4" narration hosts render from `OptimizeProgress.detail`.
    /// nil for events whose fraction advance is the whole story.
    private static func searchStageLine(_ p: VideoQualityTarget.SearchProgress) -> String? {
        switch p.stage {
        case .preparing, .finalizing:
            return nil
        case .mezzanine(let toneMapSDR, let downscale):
            var parts: [String] = []
            if downscale { parts.append("downscaling") }
            if toneMapSDR { parts.append("tone-mapping HDR→SDR") }
            let what = parts.isEmpty ? "denoising" : parts.joined(separator: " + ")
            return "Rendering the reference mezzanine (\(what))"
        case .pass(let label, let index, let planned, let bitrate):
            return String(format: "Pass %d/%d (%@) — encoding at %.1f Mbps",
                          index, planned, label, Double(bitrate) / 1e6)
        case .scoring(_, let index, let planned):
            return "Pass \(index)/\(planned) — scoring frames"
        case .passResult(_, let p10, let cleared, let bestBitrate, let bestP10):
            let verdict = cleared ? "cleared" : "below floor"
            if let bestBitrate, let bestP10 {
                return String(format: "p10 %.1f (%@) · best so far %.1f Mbps @ p10 %.1f",
                              p10, verdict, Double(bestBitrate) / 1e6, bestP10)
            }
            return String(format: "p10 %.1f (%@)", p10, verdict)
        }
    }

    private func optimizeVideo(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date, profile: OutputProfile,
                               emit: ProgressEmit? = nil) async throws -> OptimizeResult {
        emit?(.searching, 0.02, "Preparing source — probing container and streams")
        // Destination validation FIRST (`.inMemory` is unimplemented for video; an output on the
        // input's own path is refused) — before any I/O and before any policy answer, so a bad
        // argument surfaces as `.failed`, never as a plausible-looking `.skipped`. Pure: it builds
        // URLs and throws, touching no file. The upscale branch re-resolves for itself.
        let outURL = try resolveVideoOutputURL(for: url, to: destination)
        let sourceBytes = fileSize(url)
        // ONE probe, before any routing. `.web` needs the container/codec answer for its remux
        // decision, and EVERY path — including upscale — needs the alpha answer immediately below.
        // Under `.native` the probe is gated on AVFoundation readability: the native path cannot
        // consume a Matroska container (no normalize step), so probing one is work whose only
        // outcome is the same `noVideoTrack` failure the encoder raises — the gate keeps that
        // failure exactly where it was before the probe was hoisted. (media-bridge ≥ 0.37.1 opens
        // Matroska memory-mapped, so even the web path's probe now touches header pages only;
        // below that, the fallback read the WHOLE file into RAM.) For AVFoundation containers the
        // probe is metadata-only, no decode.
        let avReadable = !((try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []).isEmpty
        let info: MediaInfo? = (profile == .web || avReadable)
            ? await MediaMetrics.time("kit.probe", lane: "io",
                                      attrs: ["input": url.lastPathComponent]) {
                try? await MediaBridge.probe(url: url)
            }
            : nil

        // ── Alpha: refuse, don't flatten ───────────────────────────────────────────────────
        // Every video deliverable this Kit produces is HEVC- or H.264-in-mp4, and no mp4
        // configuration carries an alpha channel (`AVVideoCodecType.hevcWithAlpha` writes only
        // `.mov`), so an alpha source taking the optimize path would come out OPAQUE — and nothing
        // downstream could notice: the output is a complete, plausible video, the byte win looks
        // excellent (measured −99% on a ProRes 4444 cutout, most of it the discarded alpha), and
        // SSIMULACRA2 composites both sides over an opaque ground before scoring, so a flattened
        // candidate clears its floor against a flattened reference. Keeping the original is the
        // honest outcome. Preserving alpha properly (a `.mov` HEVC-with-alpha deliverable plus a
        // metric that scores the alpha plane) is a feature, not this guard. README carries the
        // full rationale.
        if let stream = info?.videoStreams.first, Self.refusesAlpha(stream) {
            // An explicit `.hevc` pin is a conversion REQUEST, and an unhonourable request fails
            // the item (the `OutputFormat` contract) rather than reading as a policy skip.
            if options.output == .hevc {
                throw ForgeError.invalidOptions(
                    "HEVC-in-mp4 cannot carry this source's alpha channel — " + Self.alphaRefusalReason)
            }
            let kept = MediaStats(bytes: sourceBytes, width: stream.width, height: stream.height)
            return OptimizeResult(
                input: url, kind: .video, output: .none, recipe: AppliedRecipe(),
                before: kept, after: kept,   // nothing was produced — the kept original is the after-state
                status: .skipped(Self.alphaRefusalReason),
                elapsed: Date().timeIntervalSince(start))
        }

        // Upscale is a *quality* op (HD→4K), the opposite of compression — when requested and an enhancer is
        // present, run the temporally-consistent per-frame SR pipeline (V1: standalone HEVC deliverable).
        if options.upscale != .none, let enhancer {
            return try await upscaleVideo(url, to: destination, options, enhancer: enhancer,
                                          start: start, profile: profile)
        }

        let encodeProfile: VideoQualityTarget.EncodeProfile
        var webReady = false
        var encodeInput = url
        var intermediates: [URL] = []
        var remuxTemp: URL?
        switch profile {
        case .native:
            encodeProfile = .hevc
        case .web:
            webReady = Self.isWebReady(info)
            // Web-safe STREAMS in the wrong wrapper (an H.264+AAC .mov capture): the lossless
            // passthrough remux is the baseline deliverable — byte-identical quality at ~source
            // size. The search still runs (a smaller floor-clearing encode is worth having) with
            // the remux as its input AND its size bar; whichever wins ships. A failed remux
            // (container AVFoundation can't passthrough) falls through to the conversion path.
            if !webReady, Self.hasWebSafeStreams(info) {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("forge-webremux-\(UUID().uuidString).mp4")
                let remuxed = await MediaMetrics.time("kit.remux", lane: "encode") {
                    (try? await MediaBridge.remuxToMP4(input: url, output: temp)) != nil
                }
                if remuxed {
                    remuxTemp = temp
                    intermediates.append(temp)
                    encodeInput = temp
                }
            }
            if remuxTemp != nil {
                // Beat the lossless remux or don't ship: source-bitrate ceiling, strictly smaller,
                // no best-effort (the remux IS the best effort, and it is perfect).
                encodeProfile = .webH264Shrink
            } else if webReady {
                // Already web-native → the original is a valid web deliverable, so behave like the
                // native optimize (shrink or honest-skip, source-bitrate ceiling).
                encodeProfile = .webH264Shrink
            } else {
                // True conversion — 2× ceiling (H.264 needs the headroom), size never blocks
                // delivery, and a floor miss still delivers the best-effort ceiling encode.
                encodeProfile = .webH264
                // Automatic normalize: a container AVFoundation can't re-encode (MKV/WebM) routes
                // through media-bridge's pure-Swift demux → native HEVC mp4 first; the web encode
                // then runs on that intermediate. Non-native codecs surface normalize's own error.
                if let info, !info.container.isNativeApple {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("forge-webnorm-\(UUID().uuidString).mp4")
                    try await MediaMetrics.time("kit.normalize", lane: "encode",
                                                attrs: ["container": info.container.rawValue]) {
                        try await MediaBridge.normalizeVideoToHEVC(input: url, output: temp)
                    }
                    encodeInput = temp
                    intermediates.append(temp)
                }
            }
        }
        defer { for temp in intermediates { try? FileManager.default.removeItem(at: temp) } }

        // ── Camera-noise self-gate (consumer preset, macOS 26+) ────────────────────────────
        // A cheap denoise probe asks whether a conservative temporal filter would actually change
        // this clip. Clean content probes ≥ ~96 (the filter no-ops) and stays on the preset floor
        // vs the raw source; demonstrably noisy content (~65 on real handheld grain) is scored
        // against a DENOISED mezzanine at the camera floor instead — the quality-saturation path.
        // The weaker floor is unreachable by clean content BY CONSTRUCTION of the gate.
        var denoiseStrength: Float? = nil
        var cameraFloor: Double? = nil
        // The gate's disposition is receipted (`recipe.cameraGate`): `denoisedReference` alone
        // cannot tell "probed clean" from "never probed", and calibrating the threshold needs it.
        var cameraGateOutcome: String? = nil
        if case .consumer = options.quality {
            if !Self.cameraGateAllowed(options) {
                cameraGateOutcome = options.cameraGate == .off ? "off" : "suppressed"
            } else {
                emit?(.searching, 0.03, "Probing sensor noise (camera self-gate)")
                if let probe = await VideoQualityTarget.noiseProbe(input: encodeInput) {
                    if probe < ContentClassifier.Calibration.cameraNoiseGate {
                        let floor = ContentClassifier.Calibration.cameraDenoisedFloor
                        cameraFloor = floor
                        denoiseStrength = 0.1
                        cameraGateOutcome = "fired"
                        emit?(.searching, 0.04,
                              "Camera noise detected — scoring against a denoised reference at floor \(Int(floor))")
                    } else {
                        cameraGateOutcome = "clean"
                    }
                } else {
                    cameraGateOutcome = "unavailable"   // probe needs macOS 26+ / a decodable input
                }
            }
        }

        // PLANNER HINT (§6.3): an injected pre-classifier may set the class floor BEFORE the
        // first search, collapsing the ratchet's classify-then-re-search into a single search on
        // graphic content. Structurally safe: high confidence only, the same `raisedFloor` table
        // (ratchet-up only, `.custom` exempt), a behavioral post-hoc audit below, and an
        // over-reach falls back to the preset search — a wrong hint can cost an attempt, never
        // the deliverable.
        var hint: ContentHint? = nil
        var hintedFloor: Double? = nil
        // A caller-supplied class suppresses hinting outright — including `.general`, which
        // resolves to no raise. Otherwise "explicit beats estimate" would hold for `.graphic` and
        // quietly invert for `.general`, where a hint could still raise a floor the caller just
        // declined. Not classifying is also cheaper: no provider call, no model load.
        // The gate's denoised-reference regime and a hint's raise are different currencies, and
        // the gate changes what the score is measured AGAINST — so a fired gate suppresses
        // hinting outright rather than composing with it. In practice they are near-exclusive
        // (handheld sensor noise is not graphic content); this makes that explicit rather than
        // leaving the interaction to precedence order.
        if cameraFloor == nil, let hintProvider, options.contentClass == nil {
            hint = await MediaMetrics.time("kit.hint", lane: "orchestrate",
                                           attrs: ["input": encodeInput.lastPathComponent]) {
                await hintProvider.classify(encodeInput)
            }
            hintedFloor = HintedStartPolicy.startingFloor(hint: hint, preset: options.quality)
            if let hint {
                MediaMetrics.event("kit.hint.classified",
                                   attrs: ["class": hint.contentClass.rawValue,
                                           "confidence": String(format: "%.2f", hint.confidence),
                                           "applied": hintedFloor != nil ? "1" : "0"])
            }
        }
        // Precedence: an explicit class beats a probabilistic hint beats the preset. `raisedFloor`
        // is ratchet-UP only and `.custom`-exempt, so `.general` (or any already-higher floor)
        // resolves to nil here and the preset stands — a stated class can strengthen the promise,
        // never weaken it.
        let declaredFloor: Double? = options.contentClass.flatMap {
            ContentClassifier.raisedFloor(preset: options.quality, class: $0)
        }
        // Precedence: a fired camera gate > an explicit class > a probabilistic hint > the preset.
        // The first two can no longer BOTH be set: an explicit `.graphic` suppresses the gate
        // (`cameraGateAllowed`), and `.general` resolves to no raise — so the gate's position at
        // the head of this chain no longer lets it lower a floor the caller stated.
        // `baselineFloor` is what a fallback re-runs at — the gate's floor when it fired, since
        // reverting to the preset floor would score denoised frames against the wrong bar.
        let baselineFloor = cameraFloor ?? options.quality.floor
        let startFloor = cameraFloor ?? declaredFloor ?? hintedFloor ?? options.quality.floor

        // The search dominates the item's wall clock (~2 min on a 4K master, search-bound), so
        // narrate it honestly before entering: the codec, the floor, and that multiple passes run.
        emit?(.searching, 0.05,
              "Searching for the smallest \(encodeProfile.codecLabel) that clears SSIMULACRA2 ≥ "
              + "\(Int(startFloor))"
              + (cameraFloor != nil ? " (camera self-gate: denoised reference)" : "")
              + (hintedFloor != nil ? " (content hint: graphic — starting at the class floor)" : "")
              + " — several encode+score passes"
              + (fileSize(encodeInput) > 200_000_000 ? " (a large master can take a couple of minutes)" : ""))
        // DEEP PROGRESS SEAM (media-bridge 0.28.0): the search's own pass-granular
        // `SearchProgress` maps into this item's emitter — pass index/planned, the bitrate under
        // test, and the best-so-far, live. The UI already renders `detail`.
        var r = try await VideoQualityTarget.encode(input: encodeInput, output: outURL,
                                                    targetScore: startFloor,
                                                    maxHeight: options.resolution.maxHeight ?? options.quality.impliedMaxHeight,
                                                    profile: encodeProfile,
                                                    denoiseStrength: denoiseStrength,
                                                    onProgress: Self.searchProgressAdapter(emit: emit,
                                                                                           base: 0.05,
                                                                                           span: 0.90))

        // The hinted floor could not deliver → the preset-floor search the hint skipped restores
        // the contract. This is the ratchet's stash-and-restore promise, mirrored: the stricter
        // attempt ran FIRST here, so recovery means re-running at the preset floor and discarding
        // the failed attempt. Receipted, never silent — the over-reach row is exactly what the
        // hint head's calibration needs. The behavioral ratchet stays disarmed after this: the
        // raised floor already failed once on this item, and re-trying it would convert a receipt
        // into wasted searches.
        var hintOverreached = false
        if let hinted = hintedFloor, !(r.delivered && r.metTarget) {
            hintOverreached = true
            MediaMetrics.event("kit.hint.overreach", attrs: ["hinted": "\(Int(hinted))"])
            emit?(.searching, 0.5,
                  "The hinted floor (SSIMULACRA2 ≥ \(Int(hinted))) can't deliver — re-running at "
                  + "the preset floor (≥ \(Int(baselineFloor)))")
            try? FileManager.default.removeItem(at: outURL)   // a best-effort partial never leaks into the re-run
            r = try await VideoQualityTarget.encode(input: encodeInput, output: outURL,
                                                    targetScore: baselineFloor,
                                                    maxHeight: options.resolution.maxHeight ?? options.quality.impliedMaxHeight,
                                                    profile: encodeProfile,
                                                    denoiseStrength: denoiseStrength,
                                                    onProgress: Self.searchProgressAdapter(emit: emit,
                                                                                           base: 0.50,
                                                                                           span: 0.45))
        }

        // The re-encode search couldn't beat the lossless remux (smaller AND floor-met) — ship the
        // remux: byte-identical streams, ~source size, no floor claim because nothing lossy ran.
        if !r.delivered, let remuxTemp {
            try? FileManager.default.removeItem(at: outURL)
            if options.stripMetadata {
                // The passthrough remux is the ONE video path that CARRIES source metadata (the
                // container copies over losslessly, creation date / GPS included) — an honored
                // strip must scrub it. Same passthrough, empty metadata list, still no re-encode.
                // The encode paths need nothing: the writer is metadata-clean by construction.
                try await Self.scrubbingMovieMetadata(from: remuxTemp, to: outURL)
            } else {
                try FileManager.default.moveItem(at: remuxTemp, to: outURL)
            }
            let remuxBytes = fileSize(outURL)
            var recipe = AppliedRecipe()
            recipe.codec = "H.264"
            recipe.remuxed = true
            recipe.strippedMetadata = options.stripMetadata
            return OptimizeResult(
                input: url, kind: .video, output: .file(outURL), recipe: recipe,
                before: MediaStats(bytes: sourceBytes, width: r.sourceWidth, height: r.sourceHeight),
                after: MediaStats(bytes: remuxBytes, width: r.sourceWidth, height: r.sourceHeight),
                status: .optimized, elapsed: Date().timeIntervalSince(start),
                outputType: .mpeg4Movie)
        }

        var chosen = r
        // The floor the DELIVERING run actually held: an over-reach fell back to the baseline
        // (the camera floor when the gate fired, else the preset), so the receipt must not claim
        // the hinted floor the attempt abandoned.
        var effectiveFloor = hintOverreached ? baselineFloor : startFloor
        var floorRaisedFrom: Double? = nil
        var hintOutcome: HintOutcome? = hintOverreached ? .overreached : nil

        if let declared = declaredFloor {
            // An explicit class started the FIRST search at the class floor — one search, no second
            // pass. Deliberately NO post-hoc audit: the behavioral signals that audit are the same
            // ones measured unreliable (`ContentClassifier.autoDetectEnabled`), so auditing a
            // caller's stated class against them would file disagreement receipts that mean nothing.
            effectiveFloor = declared
            floorRaisedFrom = options.quality.floor
        } else if let hinted = hintedFloor, !hintOverreached {
            // The hinted start delivered at the class floor — the ratchet's second search never
            // runs (§6.3: one classify replaced an entire search). The behavioral signals still
            // audit the landing (LESSONS: behavior outranks the label): disagreement files a
            // receipt INSTEAD of a re-run — either way the deliverable cleared a floor at least
            // as strong as the preset promised. NOTE the audit thresholds were calibrated on
            // preset-floor landings; at a raised floor they are provisional — which is exactly
            // why disagreement is a receipt and not an action.
            effectiveFloor = hinted
            floorRaisedFrom = options.quality.floor
            let posthoc: ContentClassifier.ContentClass? =
                (try? await MediaMetrics.time("kit.classify", lane: "orchestrate") {
                    try await Self.behavioralClass(of: chosen, input: encodeInput,
                                                   askedFloor: hinted,
                                                   hevc: encodeProfile.codec == .hevc)
                }) ?? nil
            switch posthoc {
            case .graphic: hintOutcome = .confirmed
            case .general: hintOutcome = .unconfirmed
            case nil:      hintOutcome = .unverified
            }
            MediaMetrics.event("kit.hint.posthoc", attrs: ["outcome": hintOutcome!.rawValue])
        } else if !hintOverreached, cameraFloor == nil {
            // A fired camera gate suppresses the ratchet for the same reason it suppresses the
            // hint (above): the denoised-reference regime and a class raise are different
            // currencies, and `classRaisedFloor` anchors its overshoot signal on the PRESET floor,
            // not the camera floor the search actually held. Handheld sensor noise is not graphic
            // content; making the exclusion explicit beats leaving it to precedence order.
            // Per-class floor ratchet — planner policy (see ContentClassifier). Graphic-static
            // content clears the preset floor with huge overshoot at tiny bitrates AND is the
            // class where artifacts glare on signage, so a delivered preset-floor result gets one
            // re-run at the class floor. The first deliverable is stashed and restored if the
            // re-run cannot deliver — a stricter attempt must never cost the result already in
            // hand. Ratchet-up only; `.custom` floors are exempt inside `raisedFloor`. This is
            // the CLASSICAL path the §6.3 hint seam collapses when a provider is injected — and
            // the fallback that keeps headless/CLI runs whole (metallib boundary: no MLX here).
            let raisedFloor: Double? = (chosen.delivered && chosen.metTarget)
                ? try await MediaMetrics.time("kit.classify", lane: "orchestrate") {
                    try await Self.classRaisedFloor(for: chosen, input: encodeInput,
                                                    preset: options.quality,
                                                    hevc: encodeProfile.codec == .hevc)
                }
                : nil
            if let raised = raisedFloor,
               raised > effectiveFloor {
                // The bar honestly re-opens: a second search is genuinely more work, not a regression.
                emit?(.searching, 0.5,
                      "Graphic content detected — re-running the search at the raised floor "
                      + "(SSIMULACRA2 ≥ \(Int(raised)))")
                MediaMetrics.event("kit.ratchet", attrs: ["raised": "\(raised)"])
                // `RatchetStash` owns the stash-and-restore protocol: whatever the re-run does —
                // deliver, decline, throw, get cancelled — `outURL` is left holding a deliverable
                // and no `.forge-ratchet-*.tmp` survives. `nil` means the original was kept.
                let rerun = try await RatchetStash.attemptReplacing(
                    outURL,
                    accept: { $0.delivered && $0.metTarget }
                ) {
                    try await VideoQualityTarget.encode(input: encodeInput, output: outURL,
                                                        targetScore: raised,
                                                        maxHeight: options.resolution.maxHeight ?? options.quality.impliedMaxHeight,
                                                        profile: encodeProfile,
                                                        // Always nil here (the gate suppresses the
                                                        // ratchet) — threaded so the re-run can
                                                        // never score against a different reference
                                                        // than `recipe.denoisedReference` claims.
                                                        denoiseStrength: denoiseStrength,
                                                        onProgress: Self.searchProgressAdapter(emit: emit,
                                                                                               base: 0.50,
                                                                                               span: 0.45))
                }
                if let rerun {
                    chosen = rerun
                    floorRaisedFrom = effectiveFloor
                    effectiveFloor = raised
                }
            }
        }
        emit?(.finalizing, 0.95, nil)

        var recipe = AppliedRecipe()
        recipe.codec = encodeProfile.codecLabel
        recipe.normalized = true
        // The writer carries no source metadata, so the strip guarantee holds on every encode —
        // claimed on deliveries only (a skip keeps the original, metadata and all).
        recipe.strippedMetadata = options.stripMetadata && chosen.delivered
        recipe.qualityFloor = effectiveFloor
        if let floorRaisedFrom {
            recipe.floorRaisedFrom = floorRaisedFrom
            recipe.contentClass = ContentClassifier.ContentClass.graphic.rawValue
        }
        recipe.denoisedReference = denoiseStrength != nil
        recipe.cameraGate = cameraGateOutcome
        if let hint, let hintOutcome {
            // The hint changed behavior (raised the start, or over-reached and fell back) —
            // receipt it. An ignored hint (low confidence / general / no raise applicable) is
            // metrics-only: a classification that changed nothing is not receipt material.
            recipe.contentHintClass = hint.contentClass.rawValue
            recipe.contentHintConfidence = hint.confidence
            recipe.contentHintOutcome = hintOutcome.rawValue
        }

        // `before` describes the ORIGINAL source, not the normalize intermediate.
        let before = MediaStats(bytes: sourceBytes, width: chosen.sourceWidth, height: chosen.sourceHeight)
        // Carry the reduction, not just the gating number: a bare score cannot say it is a percentile
        // over a sample, and this field being non-nil is what marks it as an aggregate (BRIDGE-061).
        // A NON-delivery keeps the original, so `after` describes IT (source bytes/dims) — never the
        // deleted trial encode, whose byte count would read as savings in any aggregate. The trial's
        // score/aggregation still ride along: they are the evidence behind the skip reason.
        // (Ported from the skip-aggregation worktree fix; its branch predates the parity rewrite.)
        let aggregation = MediaStats.QualityAggregation(percentile: chosen.aggregation.percentile,
                                                        minimum: chosen.aggregation.minimum,
                                                        mean: chosen.aggregation.mean,
                                                        framesScored: chosen.aggregation.framesScored,
                                                        frameCount: chosen.aggregation.frameCount)
        let after = chosen.delivered
            ? MediaStats(bytes: chosen.outputBytes, width: chosen.width, height: chosen.height,
                         qualityScore: chosen.score, qualityAggregation: aggregation)
            : MediaStats(bytes: sourceBytes, width: chosen.sourceWidth, height: chosen.sourceHeight,
                         qualityScore: chosen.score, qualityAggregation: aggregation)
        // A floor miss names `effectiveFloor` — the floor actually searched, the same number the
        // recipe carries — never the preset: a camera gate (75→70), a declared class (→90) or a
        // hint all move it, and citing the preset made the skip name a bar nothing was measured
        // against.
        let skipReason: String = chosen.metTarget
            ? (webReady ? "already web-ready; re-encode not smaller than source" : "not smaller than source")
            : Self.floorMissReason(effectiveFloor)
        // `output` is `.none` unless the encode delivered — it leaves NO file at `outURL` otherwise,
        // so the receipt must match (no `.file` pointing at a nonexistent path → no host orphan).
        // `delivered` is the encode profile's own rule; don't re-derive it here.
        return OptimizeResult(
            input: url, kind: .video, output: chosen.delivered ? .file(outURL) : .none,
            recipe: recipe, before: before, after: after,
            status: chosen.delivered ? .optimized : .skipped(skipReason),
            elapsed: Date().timeIntervalSince(start),
            outputType: chosen.delivered ? .mpeg4Movie : nil)   // HEVC- or H.264-in-mp4 per the profile
    }

    /// The class ratchet's decision: classify the preset-floor result mechanically and return the
    /// raised floor a fragile class earns under this preset, or nil (keep the preset floor). The
    /// signals fall out of the search that already ran: floor overshoot and emitted bits-per-pixel
    /// (duration/fps loaded from the encode input's metadata — milliseconds, no decode).
    private static func classRaisedFloor(for r: VideoQualityTarget.Result, input: URL,
                                         preset: QualityTarget,
                                         hevc: Bool) async throws -> Double? {
        // 🚨 The mechanical ratchet is GATED OFF (2026-08-16). Measured on a purpose-built signage
        // corpus it fired twice in 37 clips, both on blank synthetic test cards, and never on real
        // signage — its load-bearing signal is anti-correlated with artifact visibility. Full
        // evidence + why no threshold fixes it: `ContentClassifier.autoDetectEnabled`.
        //
        // Returning nil here means no second search: the preset floor (or an explicitly supplied
        // class floor) is what ships. Callers who want a class floor pass `Options.contentClass`.
        guard ContentClassifier.autoDetectEnabled else { return nil }
        guard let cls = try await behavioralClass(of: r, input: input, askedFloor: preset.floor,
                                                  hevc: hevc) else { return nil }
        return ContentClassifier.raisedFloor(preset: preset, class: cls)
    }

    /// The behavioral content class of a delivered search result — the same mechanical signals
    /// the ratchet classifies on (floor overshoot + emitted bits-per-pixel). `askedFloor` is the
    /// floor THIS search targeted: overshoot is only meaningful relative to what was asked — the
    /// preset floor on the ratchet path, the hinted floor on the §6.3 post-hoc audit. nil = the
    /// input's metadata could not anchor the signals (no duration / no video track).
    private static func behavioralClass(of r: VideoQualityTarget.Result, input: URL,
                                        askedFloor: Double,
                                        hevc: Bool) async throws -> ContentClassifier.ContentClass? {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0, r.width > 0, r.height > 0,
              let vtrack = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let fpsRaw = Double((try? await vtrack.load(.nominalFrameRate)) ?? 30)
        let fps = fpsRaw > 0 ? fpsRaw : 30
        let bpp = Double(r.outputBytes) * 8 / (Double(r.width * r.height) * fps * duration)
        return ContentClassifier.classify(overshoot: r.score - askedFloor, bitsPerPixel: bpp,
                                          hevc: hevc)
    }

    /// The file browsers already play as-is: mp4 container, one H.264 video stream, AAC (or no) audio.
    /// Probed, not extension-guessed; unprobeable → not web-ready → the conversion delivers.
    static func isWebReadyVideo(_ url: URL) async -> Bool {
        Self.isWebReady(try? await MediaBridge.probe(url: url))
    }

    static func isWebReady(_ info: MediaInfo?) -> Bool {
        hasWebSafeStreams(info) && info?.container == .mp4
    }

    /// The stream test alone: one H.264 video track and AAC (or no) audio — payloads a browser
    /// plays regardless of wrapper. True with a non-mp4 container = the remux candidate.
    static func hasWebSafeStreams(_ info: MediaInfo?) -> Bool {
        guard let info, info.videoStreams.count == 1,
              info.videoStreams.first?.codecID == "V_MPEG4/ISO/AVC" else { return false }
        return info.audioStreams.allSatisfy { $0.codecID == "A_AAC" }
    }

    /// V4b — temporally-consistent video upscale: per-frame engine SR (the `ImageEnhancer`, applying the
    /// requested upscale factor) + SEA-RAFT flow-guided stabilization, written as an opaque HEVC deliverable.
    /// Standalone (V1): the upscaled clip IS the output — composing with the SSIMULACRA2 quality-target encode
    /// is a later refinement. Net-clean: the SR + flow models are the injected seams.
    /// `.web` composes exactly that refinement out of necessity: the SR pipeline writes HEVC, so the
    /// upscale lands in a temp intermediate and the web target-quality encode (H.264 + AAC, floor
    /// measured against the upscaled intermediate) produces the deliverable.
    private func upscaleVideo(_ url: URL, to destination: Destination, _ options: Options,
                              enhancer: any ImageEnhancer, start: Date,
                              profile: OutputProfile) async throws -> OptimizeResult {
        let outURL = try resolveVideoOutputURL(for: url, to: destination)
        // Measure the SOURCE before the pipeline runs. `outURL` can resolve to the input's own path, in
        // which case reading it afterwards reports the output's geometry as the input's — which is how
        // `before` came to describe the file that replaced it.
        let src = await Self.videoDimensions(url)
        let inBytes = fileSize(url)
        let flowProv = self.flowProvider
        let sinkURL = profile == .web
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-upweb-\(UUID().uuidString).mp4")
            : outURL
        defer { if profile == .web { try? FileManager.default.removeItem(at: sinkURL) } }
        let outcome = try await VideoConsistencyPipeline.enhanceToVideo(
            input: url, output: sinkURL,
            enhance: { try await enhancer.enhance($0, options: options) },
            flow: { a, b in
                if let flowProv { return try await flowProv.flow(a, b) }
                return DenseFlow(width: a.width, height: a.height,
                                 uv: [Float](repeating: 0, count: a.width * a.height * 2))   // no provider → no stabilization
            })

        var recipe = AppliedRecipe()
        let before = MediaStats(bytes: inBytes, width: src.w, height: src.h)
        guard outcome.framesWritten > 0, fileSize(sinkURL) > 0 else {
            try? FileManager.default.removeItem(at: sinkURL)
            recipe.codec = profile == .web ? "H.264" : "HEVC"
            recipe.setUpscale(measuredFrom: src.w, to: 0, requested: options.upscale)
            return OptimizeResult(
                input: url, kind: .video, output: .none, recipe: recipe, before: before,
                after: before,   // nothing was produced — the kept original is the after-state
                status: .skipped("upscale produced no output"),
                elapsed: Date().timeIntervalSince(start))
        }

        if profile == .web {
            // Web deliverable from the upscaled intermediate; the floor gates the *encode* (reference
            // = the upscaled clip — visually-the-same means "same as what the SR produced").
            let r = try await VideoQualityTarget.encode(input: sinkURL, output: outURL,
                                                        targetScore: options.quality.floor,
                                                        profile: .webH264)
            let dst = r.delivered ? await Self.videoDimensions(outURL) : (w: 0, h: 0)
            recipe.codec = "H.264"
            recipe.qualityFloor = options.quality.floor
            recipe.strippedMetadata = options.stripMetadata && r.delivered   // writer-clean
            recipe.setUpscale(measuredFrom: src.w, to: dst.w, requested: options.upscale)
            let aggregation = MediaStats.QualityAggregation(percentile: r.aggregation.percentile,
                                                            minimum: r.aggregation.minimum,
                                                            mean: r.aggregation.mean,
                                                            framesScored: r.aggregation.framesScored,
                                                            frameCount: r.aggregation.frameCount)
            // Non-delivery keeps the original → `after` = source bytes/dims; the floor evidence
            // (score/aggregation) still rides along.
            let after = r.delivered
                ? MediaStats(bytes: r.outputBytes, width: dst.w, height: dst.h,
                             qualityScore: r.score, qualityAggregation: aggregation)
                : MediaStats(bytes: before.bytes, width: src.w, height: src.h,
                             qualityScore: r.score, qualityAggregation: aggregation)
            return OptimizeResult(
                input: url, kind: .video, output: r.delivered ? .file(outURL) : .none,
                recipe: recipe, before: before, after: after,
                status: r.delivered ? .optimized : .skipped(Self.floorMissReason(options.quality.floor)),
                elapsed: Date().timeIntervalSince(start),
                outputType: r.delivered ? .mpeg4Movie : nil)
        }

        let outBytes = fileSize(outURL)
        let dst = await Self.videoDimensions(outURL)
        recipe.codec = "HEVC"
        recipe.strippedMetadata = options.stripMetadata   // writer-clean delivery
        recipe.setUpscale(measuredFrom: src.w, to: dst.w, requested: options.upscale)
        let after = MediaStats(bytes: outBytes, width: dst.w, height: dst.h)
        return OptimizeResult(
            input: url, kind: .video, output: .file(outURL),
            recipe: recipe, before: before, after: after,
            status: .optimized,
            elapsed: Date().timeIntervalSince(start),
            outputType: .mpeg4Movie)
    }

    /// Rewrap an mp4 with its asset-level metadata REPLACED by none — a passthrough export, no
    /// re-encode. The strip guarantee's video half: encode paths write metadata-clean by
    /// construction; the remux fast-path copies the container and needs this. Throws on failure —
    /// under `stripMetadata` a delivery that silently kept its metadata would be worse than a
    /// failed item.
    static func scrubbingMovieMetadata(from input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetPassthrough) else {
            throw ForgeError.renderFailed("no passthrough session for the metadata scrub")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.metadata = []                     // replace carried metadata with none
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed: cont.resume()
                default: cont.resume(throwing: ForgeError.renderFailed(
                    "metadata scrub failed: \(export.error?.localizedDescription ?? "status \(export.status.rawValue)")"))
                }
            }
        }
        guard ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            throw ForgeError.renderFailed("metadata scrub produced no bytes")
        }
    }

    /// Pixel dimensions of a video's first video track (0×0 if unreadable).
    static func videoDimensions(_ url: URL) async -> (w: Int, h: Int) {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return (0, 0) }
        return (Int(abs(size.width).rounded()), Int(abs(size.height).rounded()))
    }

    // MARK: - Helpers (file + classification)

    func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// A decoded still with EXIF orientation BAKED into the pixels, plus the source's carried
    /// metadata (nil when it has none).
    struct OrientedStill {
        let image: CGImage
        let metadata: CGImageMetadata?
    }

    /// Decode a still upright. `CGImageSourceCreateImageAtIndex` returns pixels as stored — a
    /// rotated source (EXIF orientation ≠ 1, i.e. most phone shots) decoded that way and written
    /// into a fresh container with no orientation tag ships SIDEWAYS. Baking the transform at
    /// decode makes every downstream consumer correct at once: the encode, the SSIMULACRA2
    /// reference, the enhance seam, and the receipt's dimensions all describe the upright image.
    /// The full-size transform decode is the thumbnail API at `maxPixelSize == max(w, h)` — no
    /// resample, orientation applied.
    static func loadOrientedStill(_ url: URL) -> OrientedStill? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        let orientation = (props?[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
        let w = (props?[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        var image: CGImage?
        if orientation > 1, max(w, h) > 0 {
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            ] as CFDictionary)
        }
        image = image ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
        guard let image else { return nil }
        // Metadata only when the source actually carries tags — a nil here is what lets the strip
        // path skip the forced delivery and the preserve path skip the rewrap.
        let metadata = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { meta in
            (CGImageMetadataCopyTags(meta) as? [Any])?.isEmpty == false ? meta : nil
        }
        return OrientedStill(image: image, metadata: metadata)
    }

    /// Losslessly rewrap encoded still bytes with `metadata` carried in — the compressed payload
    /// is untouched (`CGImageDestinationCopyImageSource`), so the floor search's chosen bytes stay
    /// exactly what was scored. Orientation tags are dropped: pixels were baked upright at decode,
    /// and a carried tag would rotate them a second time. Returns nil on failure; callers ship the
    /// clean encode rather than failing a delivery over metadata carriage.
    static func injectingMetadata(_ metadata: CGImageMetadata, into data: Data,
                                  type: UTType) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)
        else { return nil }
        var carried = metadata
        if let mutable = CGImageMetadataCreateMutableCopy(metadata) {
            // The one orientation mechanism: ImageIO REFUSES kCGImageDestinationOrientation
            // alongside kCGImageDestinationMetadata (OSStatus 4), so the stale tag must come out
            // of the metadata itself. Returns false when the source never carried one — fine.
            CGImageMetadataRemoveTagWithPath(mutable, nil, "tiff:Orientation" as CFString)
            carried = mutable
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: carried]
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else {
            return nil
        }
        return out as Data
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


    /// Keep a derived output off the input's own path.
    ///
    /// `<dir>/<stem>.<ext>` lands exactly on the input whenever the destination directory is the input's
    /// own and the extensions agree — which silently consumed the file `OptimizeRequest` promises stays
    /// byte-identical. A derived name is Forge's to choose, so it disambiguates; an explicitly named one
    /// is the host's, so it throws.
    static func disambiguating(_ candidate: URL, from input: URL) -> URL {
        guard candidate.standardizedFileURL == input.standardizedFileURL else { return candidate }
        let ext = candidate.pathExtension
        return candidate.deletingPathExtension()
            .appendingPathExtension("optimized")
            .appendingPathExtension(ext)
    }

    private func write(_ data: Data, for input: URL, ext: String,
                       to destination: Destination) throws -> Output {
        switch destination {
        case .inMemory:
            return .data(data)
        case .directory(let dir):
            let out = Self.disambiguating(
                dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                   .appendingPathExtension(ext), from: input)
            try data.write(to: out)
            return .file(out)
        case .alongside(let suffix):
            let stem = input.deletingPathExtension().lastPathComponent + suffix
            let out = Self.disambiguating(
                input.deletingLastPathComponent().appendingPathComponent(stem)
                     .appendingPathExtension(ext), from: input)
            try data.write(to: out)
            return .file(out)
        case .fileURL(let url):                          // host-dictated exact path
            guard url.standardizedFileURL != input.standardizedFileURL else {
                throw ForgeError.outputWouldOverwriteInput(input)
            }
            try data.write(to: url)
            return .file(url)
        }
    }

    /// Test hook for the input-immutability guarantee — the derivation is where a collision originates.
    func videoOutputURLForTesting(input: URL, destination: Destination) throws -> URL {
        try resolveVideoOutputURL(for: input, to: destination)
    }

    private func resolveVideoOutputURL(for input: URL, to destination: Destination) throws -> URL {
        switch destination {
        case .directory(let dir):
            return Self.disambiguating(
                dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                   .appendingPathExtension("mp4"), from: input)
        case .alongside(let suffix):
            let stem = input.deletingPathExtension().lastPathComponent + suffix
            return Self.disambiguating(
                input.deletingLastPathComponent().appendingPathComponent(stem)
                     .appendingPathExtension("mp4"), from: input)
        case .fileURL(let url):                          // host-dictated exact path
            guard url.standardizedFileURL != input.standardizedFileURL else {
                throw ForgeError.outputWouldOverwriteInput(input)
            }
            return url
        case .inMemory:
            throw ForgeError.notImplemented("video optimize to .inMemory (Phase A: use a directory)")
        }
    }
}

// MARK: - Integrity vocabulary mapping (Kit types stay media-bridge-free; the seam maps here)

private extension IntegrityCheck.Outcome {
    init(bridge: MediaIntegrity.Check.Outcome) {
        switch bridge {
        case .passed: self = .passed
        case .failed: self = .failed
        case .skipped: self = .skipped
        }
    }
}

private extension IntegrityReport.Verdict {
    init(bridge: MediaIntegrity.Report.Verdict) {
        switch bridge {
        case .intact: self = .intact
        case .corrupt: self = .corrupt
        case .unverified: self = .unverified
        }
    }

    /// Upgrade toward severity, never downgrade — `corrupt` is terminal, `suspect` beats
    /// `intact`/`unverified`.
    mutating func escalate(to new: Self) {
        switch (self, new) {
        case (.corrupt, _): break
        case (_, .corrupt): self = .corrupt
        case (.suspect, _): break
        case (_, .suspect): self = .suspect
        default: break
        }
    }
}
