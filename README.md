# ForgeOptimizerKit

The headless core of **ForgeOptimizer** — the Layer-3 cross-modal content optimizer of the Xocialize
stack. Three verbs over one media foundation:

| Verb | What it does | Backing |
|---|---|---|
| **analyze** | probe + **verify integrity** + recommend, read-only → `Analysis` (corrupt files yield a diagnosis, never vanish) | probe + millisecond byte walks (box chains · PNG CRCs · JPEG EOI · EBML sizes); `Options(integrity: .deep)` adds decode-to-EOF |
| **optimize** | smallest file that clears a perceptual floor → `OptimizeResult` receipt | target-quality HEIC (stills) · target-quality HEVC mp4 (video), SSIMULACRA2-guided |
| **webOptimize** | same optimizer, web-universal outputs — stills race **JPEG vs PNG**, video → **H.264 + AAC mp4**, animated **GIF → mp4** | the full pipeline below |
| **conform** | resize/crop an image to a pipeline stage's input spec → `CGImage` | `.fast` CoreGraphics resample |

**Depends on [`media-bridge`](https://github.com/xocialize/media-bridge) only** — pure-Swift, FFmpeg-free,
zero vendored binaries. Builds and tests headless (no MLX, no metallib). The perceptual/enhance tier
(model-backed restore/upscale) arrives via [`ForgeCore`](https://github.com/xocialize/ForgeCore) and is
injected through a seam — this package never links it.

## The quality model

Every lossy operation is a **search for the smallest output that clears a perceptual floor** —
per-frame [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2) for video (gated on the 10th
percentile across sampled frames, so one bad stretch can't hide behind a good mean), single-image
SSIMULACRA2 for stills. The floor is a promise; the receipt proves it.

| Preset | Floor | Meaning |
|---|---|---|
| **Visually Lossless** | ≥ 90 | not noticeable in a flicker test — hero / brand-safe |
| **Balanced** *(default)* | ≥ 80 | not noticeable side-by-side |
| **Consumer Web** | ≥ 75 **+ 1080p rung** | phone footage & sharing — research-grounded: consumer viewing is a no-reference condition, and the 1080p rung is every platform's default viewing class |
| **Aggressive** | ≥ 70 | the distribution floor — artifacts perceptible, not annoying |

**Floors only ever strengthen.** A mechanical classifier (fed by the search itself — no model, no
extra pass) detects graphic/text content — the class where compression artifacts glare — and re-runs
at a stricter floor: text under Balanced or Consumer ships at the visually-lossless tier, and the
receipt says so: `@SSIMU2≥90 (raised from 75 · graphic)`. A stricter attempt that cannot deliver
restores the result already in hand. Explicit `.custom` floors are never touched.

**Receipts are the contract.** Every result carries what actually happened: the codec chosen, the
floor asked vs achieved (with the percentile aggregation, never a bare number), raised-floor
provenance, measured-not-requested transforms, and honest skips with sizes
(`already web-ready (JPEG); re-encode ≥ source`). If nothing lossy ran, no floor is claimed.

## What the video pipeline does

- **Target-quality search** — bitrate binary search + a post-search squeeze that walks down while
  candidates keep clearing the floor; borderline candidates re-verify at 2× sampling before the
  verdict.
- **Downscale by resolution class** — `maxHeight` caps the **short side** (a 1080×1920 portrait *is*
  1080p and stays untouched). Scaling runs through a Lanczos-class mezzanine, never the encoder's
  own scaler (measured: the writer's scaler aliases texture that no bitrate buys back).
- **HDR → SDR for the web** — HLG/PQ sources (every recent iPhone) tone-map once in the mezzanine
  and ship correctly-tagged BT.709; the native profile preserves HDR untouched (HDR HEVC is a
  first-class Apple deliverable).
- **Web stills race, not classify** — a JPEG floor search runs against lossless PNG and the smaller
  guarantee-keeper ships. Transparency is detected at the **pixel** level (an unused alpha channel
  doesn't bench the race); a host-pinned URL that names a format pins it.
- **Animated GIF → mp4** — browser-convention timing (delays ≤ 10 ms play as 100 ms), floor-searched
  like any video. Single-frame GIFs are stills.
- **Audio rides along honestly** — AAC passes through byte-identical; above-web-rate AAC normalizes
  to ~96 kbps/channel on the web profiles; non-AAC transcodes to AAC-LC.
- **VFR-safe** — frame timing is preserved 1:1 through every encode.

Real, reproducible example (CC-licensed Wikimedia GIFs through `weboptimize --quality consumer`):

```
✔ newtons_cradle.gif   →H.264 @SSIMU2≥75   301 KB → 25 KB  (−92%) · SSIMU2 75.5
✔ muybridge_horse.gif  →H.264 @SSIMU2≥75   555 KB → 43 KB  (−92%) · SSIMU2 78.3
✔ rotating_earth.gif   →H.264 @SSIMU2≥75   978 KB → 245 KB (−75%) · SSIMU2 76.1
```

## Use

```swift
import ForgeOptimizerKit

let forge = ForgeOptimizer()

// optimize — native deliverables (HEIC stills, HEVC mp4 video), per-item receipts, bulk-safe
for await r in try forge.optimize(.url(input), to: .directory(outDir),
                                  Options(quality: .balanced)) {
    print(r.recipe)                       // "normalize →HEVC @SSIMU2≥80"
    print(r.before.bytes, "→", r.after.bytes, r.after.qualityScore ?? 0)
}

// webOptimize — web-universal outputs. The consumer preset: floor 75, the 1080p rung by default
// (an explicit ResolutionTarget always wins), graphic content still ratchets to 90.
for await r in try forge.webOptimize(.url(phoneClip), to: .directory(outDir),
                                     Options(quality: .consumer)) {
    if let raised = r.recipe.floorRaisedFrom {
        print("class ratchet fired: raised from \(raised) — \(r.recipe.contentClass ?? "?")")
    }
}

// analyze — read-only; corrupt files yield a diagnosis, never vanish
for await a in forge.analyze(.urls(files)) { print(a.recommendation, a.estimate.note) }

// conform — in-memory glue between pipeline segments
let next = try forge.conform(image, to: MediaSpec(size: .fit(maxWidth: 1024, maxHeight: 1024)))
```

Bulk runs return an `AsyncStream` of receipts: a per-item failure is isolated (`.failed`) and never
aborts the run; `Summary(results)` aggregates. The host-dictated-URL pipeline form
(`webOptimize(_ requests:)`) writes to exact paths and honors a format the path names.

## CLI

```
forge analyze  <file> [--deep]                 # --deep = decode-to-EOF verification
forge optimize <file> <out-dir> [--quality max|balanced|consumer|aggressive|<0–100>]
forge weboptimize <file> <out-dir> [--quality …]
```

## Build

Pure-Swift; builds with the standard toolchain (`swift build`, `swift test`). Benchmark and ship
**Release** — the SSIMULACRA2 search is ~50–150× faster than Debug.

MIT — net-distributable, no FFmpeg, no vendored binaries.
