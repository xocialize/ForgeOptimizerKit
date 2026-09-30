import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MediaMeasure
@testable import ForgeOptimizerKit

/// AB-T-0193. The GPU scorer keeps one working set per image size so the next score at that size reuses it (~116 B
/// per pixel). A large one must not outlive its item: in ForgeOptimizer an 8K Best ×4 output left ≈ 3.85 GB idle, and
/// the next item's upscale stacked on top of it — 11.68 GB of process phys where the upscaler alone needs ~7. The Kit
/// trims the idle pool to `scorerIdleRetentionBytes` after every item; these hold both sides of that policy.
final class ScorerResidencyTests: XCTestCase {

    /// 3200×3200 → one working set ≈ 1.19 GB, over the 1 GiB budget: nothing of that size may survive the item.
    func testLargeStillLeavesNoScorerStateAboveTheBudget() async throws {
        guard let scorer = SSIMULACRA2Metal.shared, scorer.residentAvailable else {
            throw XCTSkip("no Metal device / resident scorer disabled")
        }
        let result = try await optimizeTexturedStill(width: 3200, height: 3200)
        XCTAssertNotNil(result.after.qualityScore, "the search must have scored the still (status \(result.status))")
        XCTAssertLessThanOrEqual(scorer.idleWorkingSetBytes, ForgeOptimizer.scorerIdleRetentionBytes,
                                 "an over-budget working set outlived its item")
    }

    /// A small still's set stays warm for the next item of that size: the trim is a budget, not a flush.
    func testSmallStillKeepsItsScorerSetWarm() async throws {
        guard let scorer = SSIMULACRA2Metal.shared, scorer.residentAvailable else {
            throw XCTSkip("no Metal device / resident scorer disabled")
        }
        let result = try await optimizeTexturedStill(width: 640, height: 480)
        XCTAssertNotNil(result.after.qualityScore, "the search must have scored the still (status \(result.status))")
        XCTAssertGreaterThanOrEqual(scorer.idleWorkingSetBytes, 640 * 480 * 116,
                                    "the 640×480 set must still be idle in the pool, ready for reuse")
        XCTAssertLessThanOrEqual(scorer.idleWorkingSetBytes, ForgeOptimizer.scorerIdleRetentionBytes)
    }

    // MARK: - Fixtures

    /// Gradient plus deterministic texture, so the HEIC floor search runs real passes (the scorer's working set is
    /// sized to the image and checked out on every pass).
    private func optimizeTexturedStill(width w: Int, height h: Int) async throws -> OptimizeResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-scorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("still.png")

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let noise = ((x * 131 + y * 57) % 64) - 32
                let i = (y * w + x) * 4
                bytes[i] = UInt8(clamping: x * 255 / w + noise)
                bytes[i + 1] = UInt8(clamping: y * 255 / h + noise)
                bytes[i + 2] = UInt8(clamping: 128 + noise)
                bytes[i + 3] = 255
            }
        }
        let image = try bytes.withUnsafeMutableBytes { raw -> CGImage in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(src as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dst, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))

        var result: OptimizeResult?
        for await r in try ForgeOptimizer().optimize(.url(src), to: .directory(dir.appendingPathComponent("out")),
                                                     Options(quality: .balanced)) {
            result = r
        }
        return try XCTUnwrap(result)
    }
}
