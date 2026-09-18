// swift-tools-version: 6.2
import PackageDescription

// ForgeOptimizerKit — the headless ForgeOptimizer core (analyze / optimize / conform). Phase A
// depends on media-bridge ONLY (pure-Swift, FFmpeg-free) → CLI-testable, no MLX/metallib. MLXEngine
// enters at Phase B (enhance + perceptual analyze). See ../../FORGEOPTIMIZER-PRD.md.
let package = Package(
    name: "ForgeOptimizerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ForgeOptimizerKit", targets: ["ForgeOptimizerKit"]),
        .executable(name: "forge", targets: ["forge"]),
    ],
    dependencies: [
        // ≥ 0.37.0 is REQUIRED, not merely preferred (AB-A-0055):
        //  · the denoise mezzanine's audio pump is registered before video pumps inline — below
        //    this, `optimize(.consumer)` on any clip WITH audio deadlocks forever once the
        //    camera self-gate fires, and the item never returns to the host;
        //  · `VideoStreamInfo.hasAlpha` is what the alpha refusal in `optimizeVideo` reads;
        //  · 0.37.1: the Matroska demux opens files memory-mapped — `probe` (run on every video
        //    item here) no longer reads a whole MKV/WebM master into RAM to learn its track list;
        //  · 0.37.2: `VideoQualityTarget.encode` / the SR pipeline refuse alpha sources themselves
        //    (`flattenAlpha: true` is the explicit opt-in) — so `forge voptimize`, which drives the
        //    encoder directly, can no longer flatten silently either;
        //  · 0.38.0: `secondaryFloor`/`secondaryOutput` + `Result.secondary` — the harvest behind
        //    `Options.secondary` (AB-A-0059). Below this the Kit has no way to keep a scored
        //    candidate: they are all swept with the temps microseconds after the search ends;
        //  · 0.38.1: `SecondaryOutcome.deliveryFailed` — a failed COPY no longer reports as the
        //    `not-smaller` refusal, so `recipe.secondaryOutcome` cannot send a host after a
        //    dedicated search to fix what was a disk fault.
        //  · 0.39.0: the external still-encoder seam — `ExternalStillEncoder`,
        //    `MediaBridge.externalStillEncoder(for:)`, the generic floor search
        //    `ImageQualityTarget.encode(_:targetScore:codec:encoder:)` and `StillFormat.webp`.
        //    The web race's WebP lane (`Options.webLossy`, `OutputFormat.webp`) is built on all four.
        // (0.34.0 brought MediaMetrics + `encode(onProgress:)` + `denoiseStrength`/`noiseProbe`.)
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.39.0"),
    ],
    targets: [
        .target(
            name: "ForgeOptimizerKit",
            dependencies: [
                .product(name: "MediaBridge", package: "media-bridge"),
                .product(name: "ImageBridge", package: "media-bridge"),
                .product(name: "MediaMeasure", package: "media-bridge"),
                .product(name: "MediaMetrics", package: "media-bridge"),   // stage spans (FORGE_METRICS)
            ],
            // CGImage / CVPixelBuffer aren't Sendable; lifecycle is serialized — v5 keeps it a warning.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Thin CLI over the library — the "library + thin CLI" form factor (PRD §3). No arg-parser dep.
        .executableTarget(
            name: "forge",
            dependencies: [
                "ForgeOptimizerKit",
                .product(name: "MediaMeasure", package: "media-bridge"),   // for `forge score` (SSIMULACRA2 parity)
                .product(name: "MediaMetrics", package: "media-bridge"),   // FORGE_METRICS span dump
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ForgeOptimizerKitTests",
                    dependencies: ["ForgeOptimizerKit",
                                   // `AlphaVideoWriter` — synthesizes the ProRes 4444 /
                                   // HEVC-with-alpha fixtures the alpha-refusal tests need.
                                   .product(name: "MediaMeasure", package: "media-bridge")]),
    ]
)
