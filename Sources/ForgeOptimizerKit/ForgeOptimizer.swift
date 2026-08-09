import Foundation
import AVFoundation
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

    /// Phase-B optical-flow seam (SEA-RAFT) for temporally-consistent *video* upscale. `nil` → the video
    /// upscale path runs per-frame SR without flicker stabilization (zero flow).
    private let flowProvider: (any VideoFlowProvider)?

    public init(enhancer: (any ImageEnhancer)? = nil, flowProvider: (any VideoFlowProvider)? = nil) {
        self.enhancer = enhancer
        self.flowProvider = flowProvider
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
                recipe.codec = "HEIC"
                recipe.qualityFloor = options.quality.floor
                recipe.normalized = meta.format != .heic
                let estimate = SavingsEstimate(
                    estimatedFraction: nil,
                    note: "run optimize for actual savings (target SSIMULACRA2 ≥ \(Int(options.quality.floor)))")
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
                         _ options: Options = .init()) throws -> AsyncStream<OptimizeResult> {
        try stream(source, to: destination, options, profile: .native)
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
                            _ options: Options = .init()) throws -> AsyncStream<OptimizeResult> {
        try stream(source, to: destination, options, profile: .web)
    }

    private func stream(_ source: Source, to destination: Destination, _ options: Options,
                        profile: OutputProfile) throws -> AsyncStream<OptimizeResult> {
        try prepareDestination(destination)
        let urls = source.urls
        return AsyncStream { continuation in
            Task {
                for url in urls {
                    let start = Date()
                    do {
                        continuation.yield(try await optimizeOne(url, to: destination, options,
                                                                 start: start, profile: profile))
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
                for req in requests {
                    let start = Date()
                    progress?(OptimizeProgress(context: req.context, input: req.input,
                                               phase: .searching, fraction: 0))
                    do {
                        try prepareDestination(.fileURL(req.output))
                        let r = try await optimizeOne(req.input, to: .fileURL(req.output), req.options,
                                                      start: start, profile: profile)
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
                             start: Date, profile: OutputProfile = .native) async throws -> OptimizeResult {
        switch mediaKind(of: url) {
        case .image: return try await optimizeImage(url, to: destination, options, start: start,
                                                    profile: profile)
        case .video: return try await optimizeVideo(url, to: destination, options, start: start,
                                                    profile: profile)
        case .unknown: throw ForgeError.unsupportedMedia(url)
        }
    }

    /// Image path: optional engine enhance → target-quality HEIC via media-bridge's SSIMULACRA2
    /// search (`.native`), or lossless PNG with the measured round-trip score (`.web`).
    private func optimizeImage(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date, profile: OutputProfile) async throws -> OptimizeResult {
        let inBytes = fileSize(url)
        guard var cg = loadCGImage(url) else { throw ForgeError.decodeFailed(url) }

        var recipe = AppliedRecipe()
        recipe.normalized = true

        let before = MediaStats(bytes: inBytes, width: cg.width, height: cg.height)

        // Phase B: engine-backed restore/upscale before encode (opt-in + enhancer present).
        let enhanced = options.enhance != .off && enhancer != nil
        if enhanced, let enhancer {
            let widthBefore = cg.width
            cg = try await enhancer.enhance(cg, options: options)
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

        // GPU-accelerate the SSIMULACRA2 — full-GPU per-channel path (CPU fallback when no Metal device).
        let scalars = SSIMULACRA2Metal.shared?.channelScalarsFunction
        let data: Data
        let score: Double
        var webExt = "png"
        var webType: UTType = .png
        switch profile {
        case .native:
            let encoded = try await ImageQualityTarget.encodeHEIC(cg, targetScore: options.quality.floor,
                                                                  channelScalars: scalars)
            data = encoded.data; score = encoded.score
            recipe.codec = "HEIC"
            recipe.qualityFloor = options.quality.floor
        case .web:
            // The web still is a RACE, not a classification: the lossless PNG always runs; a JPEG
            // floor search runs alongside unless the image carries alpha (JPEG has none). Ship the
            // smaller deliverable that keeps its guarantee — photos land 5–10× under PNG via JPEG,
            // flat graphics ring + inflate under JPEG and PNG wins on size, transparency is PNG by
            // construction. No content classifier to mis-tune; the outcome decides.
            let png = try await ImageQualityTarget.encodePNG(cg, channelScalars: scalars)
            // Gate on TRUE transparency, not channel presence: opaque-RGBA is everywhere in
            // consumer content (screenshots, decoded video frames, editor exports), and treating
            // the mere existence of an alpha channel as transparency silently benched the JPEG
            // race on exactly the photos it exists for (a real 6 MP frame shipped 2.3 MB PNG
            // where JPEG@floor measured 0.5 MB — caught by the skip receipt, 2026-08-09).
            var jpeg: ImageQualityTarget.Result?
            if pinnedExt != "png", !Self.hasRealTransparency(cg) {
                jpeg = try await ImageQualityTarget.encodeJPEG(cg, targetScore: options.quality.floor,
                                                               channelScalars: scalars)
            }
            let jpegPinned = pinnedExt == "jpg" || pinnedExt == "jpeg"
            if let jpeg, jpegPinned || (jpeg.metTarget && jpeg.data.count < png.data.count) {
                data = jpeg.data; score = jpeg.score
                recipe.codec = "JPEG"
                recipe.qualityFloor = options.quality.floor
                webExt = "jpg"; webType = .jpeg
            } else {
                data = png.data; score = png.score
                recipe.codec = "PNG"
                recipe.qualityFloor = nil                       // PNG has no floor: lossless
            }
        }

        // Honest skip applies to the non-enhanced path only — enhance is an explicit opt-in transform.
        // Native: skip whenever the re-encode isn't smaller. Web: skip only when the input is
        // already web-native (PNG or JPEG) — the original itself is a valid web deliverable and a
        // bigger re-encode would be a strict loss — EXCEPT when a host-pinned URL requests a
        // DIFFERENT format: that is a format conversion, and a conversion delivers even when
        // larger (the same semantics the video path gives non-web-native sources).
        let webNativeFormat = profile == .web ? webNativeStillFormat(url) : nil
        let pinnedMatchesSource = pinnedExt == nil
            || (pinnedExt == "png" && webNativeFormat == "PNG")
            || ((pinnedExt == "jpg" || pinnedExt == "jpeg") && webNativeFormat == "JPEG")
        let sizeGated = profile == .native || (webNativeFormat != nil && pinnedMatchesSource)
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

        let output = try write(data, for: url, ext: profile == .web ? webExt : "heic", to: destination)
        return OptimizeResult(
            input: url, kind: .image, output: output, recipe: recipe, before: before,
            after: MediaStats(bytes: data.count, width: cg.width, height: cg.height,
                              qualityScore: score),
            status: .optimized, elapsed: Date().timeIntervalSince(start),
            outputType: profile == .web ? webType : .heic)
    }

    /// The input's *actual* still format is PNG (probed, not extension-guessed). Unprobeable inputs
    /// count as not-PNG: the conversion then delivers, which is the safe direction for a web verb.
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

    /// "PNG"/"JPEG" when the source is already a web-native still (the honest-skip gate names the
    /// actual format), nil otherwise.
    private func webNativeStillFormat(_ url: URL) -> String? {
        switch (try? ImageBridgeFactory.makeProbe().probe(url: url))?.format {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        default: return nil
        }
    }

    private func isPNGSource(_ url: URL) -> Bool {
        (try? ImageBridgeFactory.makeProbe().probe(url: url))?.format == .png
    }

    /// Video path: **target-quality** — smallest encode whose per-frame p10 SSIMULACRA2 clears the
    /// floor (GPU-scored), colour preserved. `.native` → HEVC, audio passthrough-muxed; `.web` →
    /// H.264 + AAC (the mp4 every browser plays), delivered even when larger unless the source is
    /// already web-native. Same resolution by default; `options.resolution = .maxHeight(_)` steps it
    /// down (4K→HD), quality measured at the target resolution.
    private func optimizeVideo(_ url: URL, to destination: Destination, _ options: Options,
                               start: Date, profile: OutputProfile) async throws -> OptimizeResult {
        // Upscale is a *quality* op (HD→4K), the opposite of compression — when requested and an enhancer is
        // present, run the temporally-consistent per-frame SR pipeline (V1: standalone HEVC deliverable).
        if options.upscale != .none, let enhancer {
            return try await upscaleVideo(url, to: destination, options, enhancer: enhancer,
                                          start: start, profile: profile)
        }

        let outURL = try resolveVideoOutputURL(for: url, to: destination)
        let sourceBytes = fileSize(url)
        let encodeProfile: VideoQualityTarget.EncodeProfile
        var webReady = false
        var encodeInput = url
        var intermediates: [URL] = []
        var remuxTemp: URL?
        switch profile {
        case .native:
            encodeProfile = .hevc
        case .web:
            let info = try? await MediaBridge.probe(url: url)
            webReady = Self.isWebReady(info)
            // Web-safe STREAMS in the wrong wrapper (an H.264+AAC .mov capture): the lossless
            // passthrough remux is the baseline deliverable — byte-identical quality at ~source
            // size. The search still runs (a smaller floor-clearing encode is worth having) with
            // the remux as its input AND its size bar; whichever wins ships. A failed remux
            // (container AVFoundation can't passthrough) falls through to the conversion path.
            if !webReady, Self.hasWebSafeStreams(info) {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("forge-webremux-\(UUID().uuidString).mp4")
                if (try? await MediaBridge.remuxToMP4(input: url, output: temp)) != nil {
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
                    try await MediaBridge.normalizeVideoToHEVC(input: url, output: temp)
                    encodeInput = temp
                    intermediates.append(temp)
                }
            }
        }
        defer { for temp in intermediates { try? FileManager.default.removeItem(at: temp) } }

        let r = try await VideoQualityTarget.encode(input: encodeInput, output: outURL,
                                                    targetScore: options.quality.floor,
                                                    maxHeight: options.resolution.maxHeight,
                                                    profile: encodeProfile)

        // The re-encode search couldn't beat the lossless remux (smaller AND floor-met) — ship the
        // remux: byte-identical streams, ~source size, no floor claim because nothing lossy ran.
        if !r.delivered, let remuxTemp {
            let remuxBytes = fileSize(remuxTemp)
            try? FileManager.default.removeItem(at: outURL)
            try FileManager.default.moveItem(at: remuxTemp, to: outURL)
            var recipe = AppliedRecipe()
            recipe.codec = "H.264"
            recipe.remuxed = true
            return OptimizeResult(
                input: url, kind: .video, output: .file(outURL), recipe: recipe,
                before: MediaStats(bytes: sourceBytes, width: r.sourceWidth, height: r.sourceHeight),
                after: MediaStats(bytes: remuxBytes, width: r.sourceWidth, height: r.sourceHeight),
                status: .optimized, elapsed: Date().timeIntervalSince(start),
                outputType: .mpeg4Movie)
        }

        // Per-class floor ratchet — planner policy (see ContentClassifier). Graphic-static content
        // clears the preset floor with huge overshoot at tiny bitrates AND is the class where
        // artifacts glare on signage, so a delivered preset-floor result gets one re-run at the
        // class floor. The first deliverable is stashed and restored if the re-run cannot deliver —
        // a stricter attempt must never cost the result already in hand. Ratchet-up only; `.custom`
        // floors are exempt inside `raisedFloor`.
        var chosen = r
        var effectiveFloor = options.quality.floor
        var floorRaisedFrom: Double? = nil
        if chosen.delivered, chosen.metTarget,
           let raised = try await Self.classRaisedFloor(for: chosen, input: encodeInput,
                                                        preset: options.quality),
           raised > effectiveFloor {
            let stash = outURL.deletingLastPathComponent()
                .appendingPathComponent(".forge-ratchet-\(UUID().uuidString).tmp")
            try FileManager.default.moveItem(at: outURL, to: stash)
            let rerun = try await VideoQualityTarget.encode(input: encodeInput, output: outURL,
                                                            targetScore: raised,
                                                            maxHeight: options.resolution.maxHeight,
                                                            profile: encodeProfile)
            if rerun.delivered, rerun.metTarget {
                chosen = rerun
                floorRaisedFrom = effectiveFloor
                effectiveFloor = raised
                try? FileManager.default.removeItem(at: stash)
            } else {
                try? FileManager.default.removeItem(at: outURL)
                try FileManager.default.moveItem(at: stash, to: outURL)
            }
        }

        var recipe = AppliedRecipe()
        recipe.codec = encodeProfile.codecLabel
        recipe.normalized = true
        recipe.qualityFloor = effectiveFloor
        if let floorRaisedFrom {
            recipe.floorRaisedFrom = floorRaisedFrom
            recipe.contentClass = ContentClassifier.ContentClass.graphic.rawValue
        }

        // `before` describes the ORIGINAL source, not the normalize intermediate.
        let before = MediaStats(bytes: sourceBytes, width: chosen.sourceWidth, height: chosen.sourceHeight)
        // Carry the reduction, not just the gating number: a bare score cannot say it is a percentile
        // over a sample, and this field being non-nil is what marks it as an aggregate (BRIDGE-061).
        let after = MediaStats(bytes: chosen.outputBytes, width: chosen.width, height: chosen.height,
                               qualityScore: chosen.score,
                               qualityAggregation: .init(percentile: chosen.aggregation.percentile,
                                                         minimum: chosen.aggregation.minimum,
                                                         mean: chosen.aggregation.mean,
                                                         framesScored: chosen.aggregation.framesScored,
                                                         frameCount: chosen.aggregation.frameCount))
        // `output` is `.none` unless the encode delivered — it leaves NO file at `outURL` otherwise,
        // so the receipt must match (no `.file` pointing at a nonexistent path → no host orphan).
        // `delivered` is the encode profile's own rule; don't re-derive it here.
        return OptimizeResult(
            input: url, kind: .video, output: chosen.delivered ? .file(outURL) : .none,
            recipe: recipe, before: before, after: after,
            status: chosen.delivered ? .optimized
                                : .skipped(chosen.metTarget ? (webReady ? "already web-ready; re-encode not smaller than source"
                                                                        : "not smaller than source")
                                                            : "couldn't reach the SSIMU2 ≥ \(Int(options.quality.floor)) floor"),
            elapsed: Date().timeIntervalSince(start),
            outputType: chosen.delivered ? .mpeg4Movie : nil)   // HEVC- or H.264-in-mp4 per the profile
    }

    /// The class ratchet's decision: classify the preset-floor result mechanically and return the
    /// raised floor a fragile class earns under this preset, or nil (keep the preset floor). The
    /// signals fall out of the search that already ran: floor overshoot and emitted bits-per-pixel
    /// (duration/fps loaded from the encode input's metadata — milliseconds, no decode).
    private static func classRaisedFloor(for r: VideoQualityTarget.Result, input: URL,
                                         preset: QualityTarget) async throws -> Double? {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0, r.width > 0, r.height > 0,
              let vtrack = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let fpsRaw = Double((try? await vtrack.load(.nominalFrameRate)) ?? 30)
        let fps = fpsRaw > 0 ? fpsRaw : 30
        let bpp = Double(r.outputBytes) * 8 / (Double(r.width * r.height) * fps * duration)
        let cls = ContentClassifier.classify(overshoot: r.score - preset.floor, bitsPerPixel: bpp)
        return ContentClassifier.raisedFloor(preset: preset, class: cls)
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
                after: MediaStats(bytes: 0, width: 0, height: 0),
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
            recipe.setUpscale(measuredFrom: src.w, to: dst.w, requested: options.upscale)
            let after = MediaStats(bytes: r.outputBytes, width: dst.w, height: dst.h,
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
                                    : .skipped("couldn't reach the SSIMU2 ≥ \(Int(options.quality.floor)) floor"),
                elapsed: Date().timeIntervalSince(start),
                outputType: r.delivered ? .mpeg4Movie : nil)
        }

        let outBytes = fileSize(outURL)
        let dst = await Self.videoDimensions(outURL)
        recipe.codec = "HEVC"
        recipe.setUpscale(measuredFrom: src.w, to: dst.w, requested: options.upscale)
        let after = MediaStats(bytes: outBytes, width: dst.w, height: dst.h)
        return OptimizeResult(
            input: url, kind: .video, output: .file(outURL),
            recipe: recipe, before: before, after: after,
            status: .optimized,
            elapsed: Date().timeIntervalSince(start),
            outputType: .mpeg4Movie)
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
