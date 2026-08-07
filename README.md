# ForgeOptimizerKit

The headless core of **ForgeOptimizer** — the Layer-3 cross-modal content optimizer of the Xocialize
stack. Three verbs over one media foundation:

| Verb | What it does | Phase A backing |
|---|---|---|
| **analyze** | probe + **verify integrity** + recommend, read-only → `Analysis` (corrupt files yield a diagnosis, never vanish) | probe + millisecond byte walks (box chains · PNG CRCs · JPEG EOI · EBML sizes); `Options(integrity: .deep)` adds decode-to-EOF |
| **optimize** | smallest file that clears a perceptual floor → `OptimizeResult` receipt | target-quality HEIC (SSIMULACRA2-guided) · video → normalize |
| **webOptimize** | same optimizer, web-universal outputs: stills → **PNG** (lossless), video → **H.264 + AAC mp4**. Non-web-native inputs **always convert** — auto-normalize for MKV/WebM, best-effort delivery on a floor miss | PNG w/ measured round-trip score · target-quality H.264 (same SSIMULACRA2 floor, honest shortfall on the receipt) |
| **conform** | resize/crop an image to a pipeline stage's input spec → `CGImage` | `.fast` CoreGraphics resample |

**Phase A depends on [`media-bridge`](https://github.com/xocialize/media-bridge) only** — pure-Swift, FFmpeg-free, zero vendored
binaries. It builds and tests headless (no MLX, no metallib). The MLXEngine (perceptual `analyze`,
`enhance`, `.quality` `conform`) arrives in **Phase B**. The perceptual/enhance tier lands via [`ForgeCore`](https://github.com/xocialize/ForgeCore).

## Use

```swift
import ForgeOptimizerKit

let forge = ForgeOptimizer()

// optimize — target-quality (default: SSIMULACRA2 ≥ 85), per-item receipts, bulk-safe
for await r in try forge.optimize(.url(input), to: .directory(outDir),
                                  Options(quality: .balanced)) {
    print(r.recipe, r.before.bytes, "→", r.after.bytes, r.after.qualityScore ?? 0)
}

// webOptimize — same receipts, web-universal outputs: stills → PNG (lossless — visually identical
// by definition, round-trip score measured), video → H.264 + AAC mp4 (plays in every browser).
// A non-web-native input ALWAYS converts: larger is fine, a floor miss delivers the best-effort
// ceiling encode (receipt carries the honest shortfall), and MKV/WebM auto-normalize through the
// pure-Swift path first. Only an input that is already web-native (PNG / H.264-mp4) keeps the
// honest "not smaller → skip" — there the original itself is the web deliverable.
for await r in try forge.webOptimize(.url(input), to: .directory(outDir)) {
    print(r.recipe, r.before.bytes, "→", r.after.bytes)
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
forge analyze  <file> [--deep]                       # --deep = decode-to-EOF verification
forge optimize <file> <out-dir> [--quality max|balanced|aggressive|<0–100>]
forge weboptimize <file> <out-dir> [--quality …]     # web outputs: PNG · H.264+AAC mp4
```

## Build

Pure-Swift; builds with the standard toolchain. On this machine use the Xcode-beta toolchain
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build|test`).

MIT — net-distributable, no FFmpeg, no vendored binaries.
