import Foundation
import CoreGraphics
import ImageIO
import ForgeOptimizerKit
import MediaMeasure

// `forge` — a thin CLI over ForgeOptimizerKit, dependency-free (no swift-argument-parser, to stay
// minimal/net-clean). Phase A surfaces the two file-based verbs; `conform` is in-memory glue.
//
//   forge analyze  <file>
//   forge optimize <file> <out-dir> [--quality max|balanced|aggressive|<0–100>]
@main
struct ForgeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first else { usage(); exit(2) }
        let forge = ForgeOptimizer()

        do {
            switch verb {
            case "analyze":
                guard args.count >= 2 else { usage(); exit(2) }
                let url = URL(fileURLWithPath: args[1])
                for await a in forge.analyze(.url(url)) {
                    print("\(a.input.lastPathComponent)  \(a.kind.rawValue)  \(a.width)×\(a.height)  "
                          + "\(a.codecID)  \(bytes(a.bytes))")
                    print("  recommend: \(a.recommendation)")
                    print("  note: \(a.estimate.note)")
                }

            case "optimize":
                guard args.count >= 3 else { usage(); exit(2) }
                let url = URL(fileURLWithPath: args[1])
                let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
                let options = Options(quality: quality(from: args), resolution: resolution(from: args))
                var results: [OptimizeResult] = []
                for await r in try forge.optimize(.url(url), to: .directory(outDir), options) {
                    report(r)
                    results.append(r)
                }
                let s = Summary(results)
                print("— \(s.optimized) optimized · \(s.skipped) skipped · \(s.failed) failed · "
                      + "saved \(pct(s.savedFraction)) (\(bytes(s.bytesIn)) → \(bytes(s.bytesOut)))")

            case "sweep":
                // Re-baseline harness: every image × {max, balanced, aggressive} → CSV. Measures in
                // memory (no files written). Stills only (.inMemory video is unsupported in Phase A).
                guard args.count >= 2 else { usage(); exit(2) }
                let files = imageFiles(under: URL(fileURLWithPath: args[1]))
                print("file,preset,floor,ssimu2,before_bytes,after_bytes,saved_fraction,status")
                for f in files {
                    for (name, q): (String, QualityTarget) in
                        [("max", .max), ("balanced", .balanced), ("aggressive", .aggressive)] {
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
                // Video target-quality: smallest HEVC whose per-frame p10 SSIMULACRA2 clears the floor.
                // `--max-height N` steps the resolution down (e.g. 1080 = 4K→HD) before the search.
                guard args.count >= 4 else { usage(); exit(2) }
                let floor = quality(from: args).floor
                let maxH = args.firstIndex(of: "--max-height").flatMap {
                    args.count > $0 + 1 ? Int(args[$0 + 1]) : nil }
                let r = try await VideoQualityTarget.encode(input: URL(fileURLWithPath: args[1]),
                                                            output: URL(fileURLWithPath: args[2]),
                                                            targetScore: floor, maxHeight: maxH)
                print(String(format: "✔ %d×%d · %.1f Mbps · p10 %.1f · %@ → %@ (−%.0f%%) · met=%@",
                             r.width, r.height, Double(r.bitrate) / 1_000_000, r.score,
                             bytes(r.inputBytes), bytes(r.outputBytes),
                             r.savedFraction * 100, r.metTarget ? "yes" : "no"))

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

    static func usage() {
        FileHandle.standardError.write(Data("""
        forge — ForgeOptimizer CLI (Phase A)
          forge analyze  <file>
          forge optimize <file> <out-dir> [--quality max|balanced|aggressive|<0–100>]
          forge sweep    <file-or-dir>    re-baseline CSV: each image × all presets
          forge score    <ref> <distorted>   our SSIMULACRA2 (parity-diff vs canonical)

        """.utf8))
    }

    // MARK: - Parsing / formatting

    static func resolution(from args: [String]) -> ResolutionTarget {
        guard let i = args.firstIndex(of: "--max-height"), i + 1 < args.count,
              let h = Int(args[i + 1]) else { return .source }
        return .maxHeight(h)
    }

    static func quality(from args: [String]) -> QualityTarget {
        guard let i = args.firstIndex(of: "--quality"), i + 1 < args.count else { return .balanced }
        switch args[i + 1] {
        case "max": return .max
        case "balanced": return .balanced
        case "aggressive": return .aggressive
        default: return Double(args[i + 1]).map { .custom($0) } ?? .balanced
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
