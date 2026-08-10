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
        // ASSEMBLY BRANCH PIN: the v2 surface (TNF + denoiseStrength + SearchProgress) is on
        // media-bridge main, unreleased — the v0.28.0 tag is blocked on the HEVC-quarantined
        // suite (FB114259303). Flip to `from: "0.28.0"` when it tags; main keeps `from:`.
        .package(url: "https://github.com/xocialize/media-bridge.git",
                 revision: "8ab516b0af2bbedf20065fe690981b1fbce395c0"),
    ],
    targets: [
        .target(
            name: "ForgeOptimizerKit",
            dependencies: [
                .product(name: "MediaBridge", package: "media-bridge"),
                .product(name: "ImageBridge", package: "media-bridge"),
                .product(name: "MediaMeasure", package: "media-bridge"),
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
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ForgeOptimizerKitTests", dependencies: ["ForgeOptimizerKit"]),
    ]
)
