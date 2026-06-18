import Foundation
import ForgeOptimizerKit

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
                let options = Options(quality: quality(from: args))
                var results: [OptimizeResult] = []
                for await r in try forge.optimize(.url(url), to: .directory(outDir), options) {
                    report(r)
                    results.append(r)
                }
                let s = Summary(results)
                print("— \(s.optimized) optimized · \(s.skipped) skipped · \(s.failed) failed · "
                      + "saved \(pct(s.savedFraction)) (\(bytes(s.bytesIn)) → \(bytes(s.bytesOut)))")

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

        """.utf8))
    }

    // MARK: - Parsing / formatting

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
}
