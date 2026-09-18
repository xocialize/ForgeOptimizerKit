# ForgeOptimizerKit

The headless core of **ForgeOptimizer** — the Layer-3 cross-modal content optimizer of the Xocialize
stack. Three verbs over one media foundation:

| Verb | What it does | Backing |
|---|---|---|
| **analyze** | probe + **verify integrity** + recommend, read-only → `Analysis` (corrupt files yield a diagnosis, never vanish) | probe + millisecond byte walks (box chains · PNG CRCs · JPEG EOI · EBML sizes); `Options(integrity: .deep)` adds decode-to-EOF |
| **optimize** | smallest file that clears a perceptual floor → `OptimizeResult` receipt | target-quality HEIC (stills) · target-quality HEVC mp4 (video), SSIMULACRA2-guided |
| **webOptimize** | same optimizer, web-universal outputs — stills race **WebP (or JPEG) vs PNG**, video → **H.264 + AAC mp4**, animated **GIF → mp4** | the full pipeline below |
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
- **Web stills race, not classify** — a lossy floor search (WebP when a `webp-swift` encoder is
  registered, JPEG otherwise — `Options.webLossy`) runs against lossless PNG and the smaller
  guarantee-keeper ships. Transparency is detected at the **pixel** level (an unused alpha channel
  doesn't bench the race); a host-pinned URL that names a format pins it.
- **The WebP lane** — register an encoder once (`WebPStillEncoder.register()`, from
  [webp-swift](https://github.com/xocialize/webp-swift)) and the web race's lossy lane becomes WebP:
  ~30% under the JPEG deliverable at the same floor on the signage corpus, and it carries alpha, so
  transparent stills race instead of defaulting to PNG. Nothing registered → the JPEG race, unchanged.
  `Options(webLossy: .jpeg)` / `--web-lossy jpeg` keeps JPEG on purpose (email, Office);
  `.webp` / `--format webp` pins it and fails honestly without an encoder. WebP deliverables are
  metadata-clean (no ImageIO rewrap for WebP) and the receipt says so.
- **Animated GIF → mp4** — browser-convention timing (delays ≤ 10 ms play as 100 ms), floor-searched
  like any video. Single-frame GIFs are stills. **This is the one route that knowingly flattens
  transparency** — over white, the background a web GIF was authored against (a `<video>` has no
  alpha either) — and the receipt says so (`recipe.flattenedAlpha`, `flattened_alpha` in NDJSON).
- **Audio rides along honestly** — AAC passes through byte-identical; above-web-rate AAC normalizes
  to ~96 kbps/channel on the web profiles; non-AAC transcodes to AAC-LC.
- **Alpha video is refused, not flattened** — every video deliverable here is HEVC- or
  H.264-in-mp4, and no mp4 configuration carries an alpha channel. A ProRes 4444 or
  HEVC-with-alpha source is therefore `.skipped("alpha content …")` with the original kept (an
  explicit `output: .hevc` on such a source *fails* the item — an unhonourable conversion request,
  not a policy skip — and `analyze` recommends `passthrough` for it). It has to be a refusal rather
  than a caveat because nothing downstream could catch it: the flattened output is a complete,
  plausible video, the byte "win" is large (a measured −99%, most of it the discarded alpha), and
  SSIMULACRA2 composites both sides over an opaque ground before scoring, so a flattened candidate
  clears its floor against a flattened reference. The test is the stream's *declared* alpha
  channel (the probe never decodes), so a 4444 master whose alpha plane happens to be opaque is
  refused too — a skip is the cheap direction to be wrong in. **Stills are the opposite case: HEIC
  carries alpha and `optimize` keeps it**, so transparent stills optimize normally; the animated
  GIF → mp4 conversion is the documented exception above.
- **A second, weaker-floor rendition for free** (`Options.secondary`) — for a delivery rung a
  constrained venue can actually pull down. The floor search encodes and scores a whole ladder of
  complete deliverables and deletes every one it does not ship; ask for a secondary floor and the
  smallest candidate that cleared it is kept instead — same codec, container, resolution and muxed
  audio, no second search (measured 11.5 s → 11.4 s and 34.5 s → 34.6 s on two signage masters).
  Delivered only when it is **strictly smaller than what ships**, because a rendition that isn't
  smaller isn't one. **It is a harvest, not a search**: `SecondaryResult.provenance` renders
  `harvested @SSIMU2≥80 (from the ≥90 search)` so a ledger cannot record it as the smallest file
  that clears 80. How close it came is readable from `overshoot` — see below.
- **VFR-safe** — frame timing is preserved 1:1 through every encode.

Real, reproducible example (CC-licensed Wikimedia GIFs through `weboptimize --quality consumer`):

```
✔ newtons_cradle.gif   →H.264 @SSIMU2≥75   301 KB → 25 KB  (−92%) · SSIMU2 75.5
✔ muybridge_horse.gif  →H.264 @SSIMU2≥75   555 KB → 43 KB  (−92%) · SSIMU2 78.3
✔ rotating_earth.gif   →H.264 @SSIMU2≥75   978 KB → 245 KB (−75%) · SSIMU2 76.1
```

### What the harvested rendition actually costs you

Measured 2026-09-03 on the signage corpus (AB-A-0059) — `optimize --quality max` (floor 90) with
`--secondary-floor 80`, against a **dedicated** `--quality balanced` run of the same master:

| master (sizes MB = 10⁶ B, as the NDJSON reports them) | source | primary @90 | harvested @80 | dedicated @80 | overshoot |
|---|---|---|---|---|---|
| is_keynote_airace_1080p | 10.36 MB | *skipped* | **7.96 MB** (82.1) | 7.26 MB (80.2) | 2.1 → **+10%** |
| ibmplaycharacters_1080p | 3.22 MB | *skipped* | **2.75 MB** (82.8) | 2.49 MB (80.4) | 2.8 → **+10%** |
| tp_layersb_1080p | 3.78 MB | *skipped* | **3.22 MB** (80.7) | 2.96 MB (80.2) | 0.7 → **+9%** |
| ibmplaycharacters_master | 17.02 MB | 13.81 MB (90.3) | 10.61 MB (87.5) | **3.91 MB** (80.5) | 7.5 → **+171%** |
| tp_honda_1080p | 6.72 MB | *skipped* | `no-candidate` | *skipped* (72.1) | — |
| is_architecture_1080p | 4.17 MB | *skipped* | `no-candidate` | *skipped* (77.3) | — |

Three things to read out of it.

**The free version is near-optimal exactly when you need it.** When the primary floor is
UNREACHABLE the search spends its whole ladder around the achievable ceiling — which is where the
weaker floor lives — so the harvest lands within ~10%. When the primary floor CLEARS, the search
stops at the smallest candidate meeting it and never probes far below, so the lowest thing it ever
scored sits just under the *primary* floor (87.5, not 80) and the harvest is 2.7× a real
floor-80 file. `overshoot` (score − floor) is the tell, and it is on the receipt.

**`no-candidate` usually means the content, not the harvest.** On both masters that reported it, a
dedicated floor-80 search also skipped, at the identical scores — nothing was missed. It is still
worth distinguishing from `not-smaller`: persistent `no-candidate` on content that *can* reach the
floor is the argument for spending a real second search.

**Six masters is a calibration, not a fit.** Read the overshoot boundary as "single digits good,
high single digits worth a second look".

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

// A second rendition at a weaker floor, harvested from the same search (see the table above).
// The URL is stated, never derived: Forge writes only where the host names.
for await r in try forge.optimize(.url(master), to: .fileURL(heroURL),
                                  Options(quality: .max,
                                          secondary: .init(floor: 80, output: wifiURL))) {
    if let rung = r.secondary {
        print(rung.bytes, rung.score, rung.provenance)   // "harvested @SSIMU2≥80 (from the ≥90 search)"
        print(rung.overshoot)                            // ~2 = near-optimal · ~7 = pay for a real search
    } else {
        // Always answered, never silent: "no-candidate" · "not-smaller" · "video-only" ·
        // "unsupported-route". A host has to be able to tell a policy from a failure.
        print("no rendition:", r.recipe.secondaryOutcome ?? "-")
    }
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

`Options.cameraGate: .off` skips the `.consumer` preset's camera-noise probe. That probe is the
planner's one floor-LOWERING device — content that measures as noisy is scored against a *denoised*
reference at a weaker floor, which is right for handheld footage and wrong for anything rendered,
where the denoise softens exactly the text edges the content exists to show. Rendered material does
not always read as clean to the probe (a 1080p presentation slide measured 86.3 against a gate of
90), so on a host whose content is rendered by construction — signage, slides, motion graphics —
turn it off rather than hope. Declaring `Options.contentClass = .graphic` turns it off too and says
more: rendered content is definitionally not camera capture, and the class also raises the floor.
(`.general` deliberately does not suppress it — that value *includes* the camera footage the gate
exists for.) The receipt carries what the gate did (`recipe.cameraGate`: `off` / `suppressed` /
`clean` / `fired` / `unavailable`; `camera_gate` in NDJSON), so a host can verify its policy was
honoured and calibration rows can separate "probed clean" from "never probed".

The extension on a `.fileURL` destination is **advisory** — Forge writes its opinionated container
(HEIC stills, HEVC-in-mp4 video) to the path as given and the host reads the real container back
from `OptimizeResult.outputType`. ⚠️ **The one exception is `webOptimize` stills: a `.png`/`.jpg`
extension PINS that format**, exactly as an explicit `Options.output` would (a `.jpg` pin on real
transparency is refused, same as the option). A host that mirrors the source extension onto its
temp path therefore silently benches the PNG↔JPEG race for every PNG source, and the receipt looks
like an ordinary PNG win because it *is* one; it just never had a competitor. Pass an
**extension-less** path when you want the race to decide.

## CLI

```
forge analyze     <file> [--deep] [--json]     # --deep = decode-to-EOF verification
forge optimize    <file> <out-dir> [--quality max|balanced|consumer|aggressive|<0–100>]
                  [--max-height N] [--format auto|heic|jpeg|png|hevc] [--strip-metadata]
                  [--content-class graphic|general] [--no-camera-gate]
                  [--secondary-floor N] [--json]
forge weboptimize <file> <out-dir> [--quality …] [--max-height N] [--format …]
                  [--strip-metadata] [--content-class …] [--no-camera-gate]
                  [--secondary-floor N] [--json]
forge sweep | score | vscore | voptimize …     # run `forge` bare for the full surface
```

`--secondary-floor N` (video) also writes `<stem>.secondary.mp4` — the weaker rung, harvested from
the search that already ran. The `.secondary` in the name is deliberate: it is not the smallest file
that clears N, and a neutral name invites it into a ledger as though it were.

```
• is_keynote_airace_1080p.mp4  skipped — couldn't reach the SSIMU2 ≥ 90 floor
  ↳ is_keynote_airace_1080p.secondary.mp4  7.6 MB (−23% vs source) · SSIMU2 82.1 · harvested @SSIMU2≥80 (from the ≥90 search)
```

`--json` streams NDJSON receipts on stdout (one object per item + a summary; exit 1 on any
per-item failure). Optimize verbs narrate their stages to **stderr** as they happen — the same
`progress:` events as the library example above — so stdout stays machine-clean either way.

## Build

Pure-Swift; builds with the standard toolchain (`swift build`, `swift test`). Benchmark and ship
**Release** — the SSIMULACRA2 search is ~50–150× faster than Debug.

MIT — net-distributable, no FFmpeg, no vendored binaries.
