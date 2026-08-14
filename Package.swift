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
        // ≥ 0.28.0: MediaMetrics + `VideoQualityTarget.encode(onProgress:)` (tagged 2026-08-14;
        // the VT suite validates that tag retroactively on the next macOS beta — AB-B-0002).
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.28.0"),
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
        .testTarget(name: "ForgeOptimizerKitTests", dependencies: ["ForgeOptimizerKit"]),
    ]
)
