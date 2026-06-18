# ForgeOptimizerKit

The headless core of **ForgeOptimizer** — the Layer-3 cross-modal content optimizer of the Xocialize
stack. Three verbs over one media foundation:

| Verb | What it does | Phase A backing |
|---|---|---|
| **analyze** | probe + recommend a recipe, read-only → `Analysis` | structural (media-bridge probe) |
| **optimize** | smallest file that clears a perceptual floor → `OptimizeResult` receipt | target-quality HEIC (SSIMULACRA2-guided) · video → normalize |
| **conform** | resize/crop an image to a pipeline stage's input spec → `CGImage` | `.fast` CoreGraphics resample |

**Phase A depends on [`media-bridge`](../media-bridge) only** — pure-Swift, FFmpeg-free, zero vendored
binaries. It builds and tests headless (no MLX, no metallib). The MLXEngine (perceptual `analyze`,
`enhance`, `.quality` `conform`) arrives in **Phase B**. See `../../FORGEOPTIMIZER-PRD.md`.

## Use

```swift
import ForgeOptimizerKit

let forge = ForgeOptimizer()

// optimize — target-quality (default: SSIMULACRA2 ≥ 85), per-item receipts, bulk-safe
for await r in try forge.optimize(.url(input), to: .directory(outDir),
                                  Options(quality: .balanced)) {
    print(r.recipe, r.before.bytes, "→", r.after.bytes, r.after.qualityScore ?? 0)
}

// analyze — read-only
for await a in forge.analyze(.urls(files)) { print(a.recommendation, a.estimate.note) }

// conform — in-memory glue between model pipeline segments
let next = try forge.conform(image, to: MediaSpec(size: .fit(maxWidth: 1024, maxHeight: 1024)))
```

Bulk runs return an `AsyncStream` of receipts: a per-item failure is isolated (`.failed`) and never
aborts the run. `Summary(results)` aggregates.

## CLI

```
forge analyze  <file>
forge optimize <file> <out-dir> [--quality max|balanced|aggressive|<0–100>]
```

## Build

Pure-Swift; builds with the standard toolchain. On this machine use the Xcode-beta toolchain
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build|test`).

MIT — net-distributable, no FFmpeg, no vendored binaries.
