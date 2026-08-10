import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ForgeOptimizerKit
import MediaMeasure

// `forge` — a thin CLI over ForgeOptimizerKit, dependency-free (no swift-argument-parser, to stay
// minimal/net-clean). File-based verbs only; `conform` is in-memory inter-segment glue by design
// (PRD §3) and deliberately has no CLI form.
//
//   forge analyze     <file> [--deep] [--json]
//   forge optimize    <file> <out-dir> [--quality …] [--max-height N] [--format F] [--strip-metadata] [--json]
//   forge weboptimize <file> <out-dir> [--quality …] [--max-height N] [--format F] [--strip-metadata] [--json]
//   forge sweep       <file-or-dir>
//   forge score       <ref> <distorted> [--metal]
//   forge voptimize   <in> <out.mp4> [--quality …] [--max-height N] [--profile native|web|webshrink]
//   forge vscore      <ref> <distorted> [--stride N]
//
// `--json` streams NDJSON receipts (one object per item, then a `"type":"summary"` object) —
// stdout stays machine-clean; human diagnostics go to stderr. Exit codes: 0 = success,
// 1 = error or any per-item failure, 2 = usage.
@main
struct ForgeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first else { usage(); exit(2) }
        let forge = ForgeOptimizer()
        let json = args.contains("--json")

        do {
            switch verb {
            case "analyze":
                guard args.count >= 2 else { usage(); exit(2) }
                let url = URL(fileURLWithPath: args[1])
                let options = Options(integrity: args.contains("--deep") ? .deep : .structural)
                for await a in forge.analyze(.url(url), options) {
                    if json { emitJSON(analysisJSON(a)); continue }
                    print("\(a.input.lastPathComponent)  \(a.kind.rawValue)  \(a.width)×\(a.height)  "
                          + "\(a.codecID)  \(bytes(a.bytes))")
                    print("  integrity: \(a.integrity.summary)")
                    for c in a.integrity.checks where c.outcome != .failed {
                        print("    ✓ \(c.name)\(c.detail.map { " — \($0)" } ?? "")")
                    }
                    print("  recommend: \(a.recommendation)")
                    print("  note: \(a.estimate.note)")
                }

            case "optimize", "weboptimize":
                guard args.count >= 3 else { usage(); exit(2) }
                let url = URL(fileURLWithPath: args[1])
                let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
                let options = Options(quality: quality(from: args), resolution: resolution(from: args),
                                      output: outputFormat(from: args),
                                      stripMetadata: args.contains("--strip-metadata"))
                var results: [OptimizeResult] = []
                let stream = verb == "weboptimize"
                    ? try forge.webOptimize(.url(url), to: .directory(outDir), options)
                    : try forge.optimize(.url(url), to: .directory(outDir), options)
                for await r in stream {
                    if json { emitJSON(resultJSON(r)) } else { report(r) }
                    results.append(r)
                }
                let s = Summary(results)
                if json {
                    emitJSON(["type": "summary", "count": s.count, "optimized": s.optimized,
                              "skipped": s.skipped, "failed": s.failed,
                              "bytes_in": s.bytesIn, "bytes_out": s.bytesOut,
                              "saved_fraction": round4(s.savedFraction)])
                } else {
                    print("— \(s.optimized) optimized · \(s.skipped) skipped · \(s.failed) failed · "
                          + "saved \(pct(s.savedFraction)) (\(bytes(s.bytesIn)) → \(bytes(s.bytesOut)))")
                }
                // A run where something failed must not exit 0 — receipts are contracts, and a
                // scripting host keys off the exit code before it ever parses one.
                if s.failed > 0 { exit(1) }

            case "sweep":
                // Re-baseline harness: every image × the preset ladder → CSV. Measures in memory
                // (no files written). Stills only (.inMemory video is unsupported).
                guard args.count >= 2 else { usage(); exit(2) }
                let files = imageFiles(under: URL(fileURLWithPath: args[1]))
                print("file,preset,floor,ssimu2,before_bytes,after_bytes,saved_fraction,status")
                for f in files {
                    for (name, q): (String, QualityTarget) in
                        [("max", .max), ("balanced", .balanced), ("consumer", .consumer),
                         ("aggressive", .aggressive)] {
                        for await r in try forge.optimize(.url(f), to: .inMemory, Options(quality: q)) {
                            let score = r.after.qualityScore.map { String(format: "%.2f", $0) } ?? ""
                            print("\(f.lastPathComponent),\(name),\(Int(q.floor)),\(score),"
                                  + "\(r.before.bytes),\(r.after.bytes),"
                                  + "\(String(format: "%.4f", r.savedFraction)),\(statusWord(r.status))")
                        }
                    }
                }

            case "score":
                // Our pure-Swift SSIMULACRA2 on a (reference, distorted) pair — for parity diffing
                // against the canonical libjxl `ssimulacra2` binary. Same dimensions required.
                guard args.count >= 3 else { usage(); exit(2) }
                guard let ref = loadCGImage(URL(fileURLWithPath: args[1])),
                      let dist = loadCGImage(URL(fileURLWithPath: args[2])) else {
                    FileHandle.standardError.write(Data("error: could not load image(s)\n".utf8)); exit(1)
                }
                let score: Double
                if args.contains("--metal"), let gpu = SSIMULACRA2Metal() {
                    score = try gpu.score(reference: ref, distorted: dist)   // GPU blur backend
                } else {
                    score = try SSIMULACRA2.score(reference: ref, distorted: dist)
                }
                print(String(format: "%.4f", score))

            case "voptimize":
                // Low-level video target-quality harness: drives media-bridge's search directly
                // (no Kit semantics — no class ratchet, no consumer rung defaults). The Kit path
                // is `forge optimize`/`weboptimize` on a video file; this verb is for measuring
                // one encode with explicit knobs.
                guard args.count >= 3 else { usage(); exit(2) }
                let floor = quality(from: args).floor
                let maxH = args.firstIndex(of: "--max-height").flatMap {
                    args.count > $0 + 1 ? Int(args[$0 + 1]) : nil }
                let r = try await VideoQualityTarget.encode(input: URL(fileURLWithPath: args[1]),
                                                            output: URL(fileURLWithPath: args[2]),
                                                            targetScore: floor, maxHeight: maxH,
                                                            profile: encodeProfile(from: args))
                print(String(format: "✔ %d×%d · %.1f Mbps · p10 %.1f · %@ → %@ (−%.0f%%) · met=%@",
                             r.width, r.height, Double(r.bitrate) / 1_000_000, r.score,
                             bytes(r.inputBytes), bytes(r.outputBytes),
                             r.savedFraction * 100, r.metTarget ? "yes" : "no"))
                print("  \(r.aggregation.summary)")

            case "vscore":
                // Per-frame SSIMULACRA2 of a video pair (same resolution), aggregated. GPU-scored.
                guard args.count >= 3 else { usage(); exit(2) }
                let stride = args.firstIndex(of: "--stride").flatMap {
                    args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 24
                let vs = try VideoQuality.videoScore(reference: URL(fileURLWithPath: args[1]),
                                                     distorted: URL(fileURLWithPath: args[2]),
                                                     sampleStride: stride)
                print(String(format: "mean %.2f · min %.2f · p10 %.2f · %d frames scored",
                             vs.mean, vs.minimum, vs.p10, vs.framesScored))

            default:
                usage(); exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Output

    static func report(_ r: OptimizeResult) {
        switch r.status {
        case .optimized:
            let score = r.after.qualityScore.map { String(format: " · SSIMU2 %.1f", $0) } ?? ""
            print("✔ \(r.input.lastPathComponent)  \(r.recipe)  "
                  + "\(bytes(r.before.bytes)) → \(bytes(r.after.bytes)) (−\(pct(r.savedFraction)))\(score)")
        case .skipped(let why):
            print("• \(r.input.lastPathComponent)  skipped — \(why)")
        case .failed(let why):
            print("✘ \(r.input.lastPathComponent)  failed — \(why)")
        }
    }

    // MARK: - JSON receipts (NDJSON; keys sorted so output is stable for tooling)

    static func emitJSON(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return }
        print(s)
    }

    static func statsJSON(_ s: MediaStats) -> [String: Any] {
        var o: [String: Any] = ["bytes": s.bytes, "width": s.width, "height": s.height]
        if let q = s.qualityScore { o["ssimu2"] = round2(q) }
        if let a = s.qualityAggregation {
            o["aggregation"] = ["percentile": a.percentile, "min": round2(a.minimum),
                                "mean": round2(a.mean), "frames_scored": a.framesScored,
                                "frame_count": a.frameCount] as [String: Any]
        }
        return o
    }

    static func resultJSON(_ r: OptimizeResult) -> [String: Any] {
        var o: [String: Any] = [
            "type": "result",
            "input": r.input.path,
            "kind": r.kind.rawValue,
            "status": statusWord(r.status),
            "recipe": String(describing: r.recipe),
            "before": statsJSON(r.before),
            "after": statsJSON(r.after),
            "saved_bytes": r.savedBytes,
            "saved_fraction": round4(r.savedFraction),
            "elapsed_s": round2(r.elapsed),
        ]
        switch r.output {
        case .file(let u):  o["output"] = u.path
        case .data(let d):  o["output_inline_bytes"] = d.count
        case .none:         break
        }
        switch r.status {
        case .skipped(let why), .failed(let why): o["reason"] = why
        case .optimized: break
        }
        if let mime = r.outputType?.preferredMIMEType { o["mime"] = mime }
        // Machine-readable strip claim — a host must not have to parse the recipe prose for it.
        if r.recipe.strippedMetadata { o["stripped_metadata"] = true }
        return o
    }

    static func analysisJSON(_ a: Analysis) -> [String: Any] {
        var o: [String: Any] = [
            "type": "analysis",
            "input": a.input.path,
            "kind": a.kind.rawValue,
            "width": a.width, "height": a.height,
            "bytes": a.bytes,
            "codec": a.codecID,
            "recommendation": String(describing: a.recommendation),
            "integrity": ["verdict": a.integrity.verdict.rawValue,
                          "checks": a.integrity.checks.map {
                              var c: [String: Any] = ["name": $0.name, "outcome": $0.outcome.rawValue]
                              if let d = $0.detail { c["detail"] = d }
                              return c
                          }] as [String: Any],
            "estimate_note": a.estimate.note,
        ]
        if let q = a.qualityScore { o["quality_score"] = round2(q) }
        if let f = a.estimate.estimatedFraction { o["estimated_fraction"] = round4(f) }
        return o
    }

    // Decimal, not Double: JSONSerialization prints a rounded Double with binary-float noise
    // ("80.829999999999998"); a Decimal built from the formatted string prints "80.83".
    static func round2(_ v: Double) -> Decimal { Decimal(string: String(format: "%.2f", v)) ?? 0 }
    static func round4(_ v: Double) -> Decimal { Decimal(string: String(format: "%.4f", v)) ?? 0 }

    static func usage() {
        FileHandle.standardError.write(Data("""
        forge — ForgeOptimizer CLI

          forge analyze     <file> [--deep] [--json]
                --deep adds decode-to-EOF integrity verification
          forge optimize    <file> <out-dir> [--quality Q] [--max-height N] [--format F]
                            [--strip-metadata] [--json]
                native deliverables: HEIC stills · HEVC+AAC mp4 video
          forge weboptimize <file> <out-dir> [--quality Q] [--max-height N] [--format F]
                            [--strip-metadata] [--json]
                web deliverables: PNG/JPEG race stills · H.264+AAC mp4 video · GIF→mp4
          forge sweep       <file-or-dir>
                re-baseline CSV: each image × {max, balanced, consumer, aggressive}, in memory
          forge score       <ref> <distorted> [--metal]
                pure-Swift SSIMULACRA2 on a still pair (parity-diff vs canonical)
          forge voptimize   <in> <out.mp4> [--quality Q] [--max-height N]
                            [--profile native|web|webshrink]
                low-level video floor search (media-bridge direct; no Kit semantics)
          forge vscore      <ref> <distorted> [--stride N]
                per-frame SSIMULACRA2 of a video pair, p10-aggregated

          --quality Q       max | balanced | consumer | aggressive | <0–100>   (default balanced)
          --format F        auto | heic | jpeg | png | hevc   (default auto = the verb's policy)
                            still pins CONVERT: they deliver even when larger than the source;
                            invalid pairings (e.g. png on video, heic on weboptimize) fail the item
          --strip-metadata  metadata-clean deliverable (EXIF/GPS/IPTC/XMP; orientation is baked
                            into pixels either way) — the default preserves stills metadata
          --json            NDJSON receipts on stdout (one per item + a summary object)

        exit codes: 0 success · 1 error or any per-item failure · 2 usage

        """.utf8))
    }

    // MARK: - Parsing / formatting

    static func resolution(from args: [String]) -> ResolutionTarget {
        guard let i = args.firstIndex(of: "--max-height"), i + 1 < args.count,
              let h = Int(args[i + 1]) else { return .source }
        return .maxHeight(h)
    }

    /// `--format` → `Options.output`. A TYPO'd value exits 2 rather than silently falling back to
    /// `.auto` — an explicit format request that quietly becomes a different format is exactly the
    /// silent no-op these flags exist to end.
    static func outputFormat(from args: [String]) -> OutputFormat {
        guard let i = args.firstIndex(of: "--format"), i + 1 < args.count else { return .auto }
        switch args[i + 1].lowercased() {
        case "auto": return .auto
        case "heic": return .heic
        case "jpeg", "jpg": return .jpeg
        case "png": return .png
        case "hevc": return .hevc
        default:
            FileHandle.standardError.write(Data(
                "error: unknown --format '\(args[i + 1])' (auto | heic | jpeg | png | hevc)\n".utf8))
            exit(2)
        }
    }

    static func quality(from args: [String]) -> QualityTarget {
        guard let i = args.firstIndex(of: "--quality"), i + 1 < args.count else { return .balanced }
        switch args[i + 1] {
        case "max": return .max
        case "balanced": return .balanced
        case "consumer": return .consumer
        case "aggressive": return .aggressive
        default: return Double(args[i + 1]).map { .custom($0) } ?? .balanced
        }
    }

    static func encodeProfile(from args: [String]) -> VideoQualityTarget.EncodeProfile {
        guard let i = args.firstIndex(of: "--profile"), i + 1 < args.count else { return .hevc }
        switch args[i + 1] {
        case "web": return .webH264
        case "webshrink": return .webH264Shrink
        default: return .hevc   // "native"
        }
    }

    static func bytes(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(n), u = 0
        while v >= 1024 && u < units.count - 1 { v /= 1024; u += 1 }
        return u == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[u])
    }

    static func pct(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }

    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func statusWord(_ s: Status) -> String {
        switch s {
        case .optimized: return "optimized"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }

    /// A single image, or all images directly under a directory (sorted, non-recursive).
    static func imageFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif"]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return exts.contains(root.pathExtension.lowercased()) ? [root] : []
        }
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { exts.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
