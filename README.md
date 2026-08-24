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

// progress — a 4K floor search is minutes of real work; narrate it instead of spinning.
// `detail` carries the human stage line (bookend events carry none); `itemIndex`/`itemCount`
// locate the item in a batch. The handler fires on the optimizer's task — hop to your actor
// before touching UI (a console log needs no hop).
for await r in try forge.webOptimize(.url(master), to: .directory(outDir),
                                     Options(quality: .consumer),
                                     progress: { p in
    guard let detail = p.detail else { return }
    print("[\(p.itemIndex + 1)/\(p.itemCount)] \(detail)")
}) {
    print(r.recipe)
}
// [1/1] Preparing source — probing container and streams
// [1/1] Searching for the smallest H.264 that clears SSIMULACRA2 ≥ 75 — several encode+score
//       passes (a large master can take a couple of minutes)
// [1/1] Graphic content detected — re-running the search at the raised floor (SSIMULACRA2 ≥ 90)
//                                   ← only when the class ratchet actually fires
// Per-pass lines ("pass 3/6 · trying 8.2 Mbps · best −62%") arrive with the media-bridge
// SearchProgress adoption — same handler, richer `detail`.

// analyze — read-only; corrupt files yield a diagnosis, never vanish
for await a in forge.analyze(.urls(files)) { print(a.recommendation, a.estimate.note) }

// conform — in-memory glue between pipeline segments
let next = try forge.conform(image, to: MediaSpec(size: .fit(maxWidth: 1024, maxHeight: 1024)))
```

Bulk runs return an `AsyncStream` of receipts: a per-item failure is isolated (`.failed`) and never
aborts the run; `Summary(results)` aggregates. The host-dictated-URL pipeline form
(`webOptimize(_ requests:)`) writes to exact paths and honors a format the path names.

`Options.output` pins the deliverable format (`.heic`/`.jpeg`/`.png` for stills — conversion
semantics, so a pin delivers even when larger; `.auto` keeps each verb's policy). Invalid pairings
(a still format on video, `.heic` under the web verb, `.jpeg` on real transparency) fail the item
honestly. `Options.stripMetadata: true` guarantees a metadata-clean deliverable (EXIF/GPS/IPTC/XMP
shed; the receipt carries `strippedMetadata`); the default preserves a still's source metadata.
Orientation is baked into pixels either way, so rotated phone shots ship upright.

## CLI

```
<<<<<<< HEAD
forge analyze     <file> [--deep] [--json]     # --deep = decode-to-EOF verification
forge optimize    <file> <out-dir> [--quality max|balanced|consumer|aggressive|<0–100>]
                  [--max-height N] [--json]
forge weboptimize <file> <out-dir> [--quality …] [--max-height N] [--json]
forge sweep | score | vscore | voptimize …     # run `forge` bare for the full surface
=======
forge analyze  <file> [--deep]                 # --deep = decode-to-EOF verification
forge optimize <file> <out-dir> [--quality max|balanced|consumer|aggressive|<0–100>]
                                [--format auto|heic|jpeg|png|hevc] [--strip-metadata]
forge weboptimize <file> <out-dir> [--quality …] [--format …] [--strip-metadata]
>>>>>>> claude/reverent-raman-9263d5
```

`--json` streams NDJSON receipts on stdout (one object per item + a summary; exit 1 on any
per-item failure). Optimize verbs narrate their stages to **stderr** as they happen — the same
`progress:` events as the library example above — so stdout stays machine-clean either way.

## Build

Pure-Swift; builds with the standard toolchain (`swift build`, `swift test`). Benchmark and ship
**Release** — the SSIMULACRA2 search is ~50–150× faster than Debug.

MIT — net-distributable, no FFmpeg, no vendored binaries.
