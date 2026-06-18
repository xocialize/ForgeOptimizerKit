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
        .package(path: "../media-bridge"),
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
            dependencies: ["ForgeOptimizerKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ForgeOptimizerKitTests", dependencies: ["ForgeOptimizerKit"]),
    ]
)
