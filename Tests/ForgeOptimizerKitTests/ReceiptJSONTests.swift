import XCTest
import Foundation
@testable import ForgeOptimizerKit

/// The receipt is one shape for the CLI and every host: these pin the keys, the sorted-key
/// stability, and the decimal rounding that keeps "80.83" from printing as binary-float noise.
final class ReceiptJSONTests: XCTestCase {

    private func sample(status: Status = .optimized) -> OptimizeResult {
        var recipe = AppliedRecipe()
        recipe.codec = "WebP"; recipe.qualityFloor = 80; recipe.strippedMetadata = true
        return OptimizeResult(
            input: URL(fileURLWithPath: "/in/a.png"), kind: .image,
            output: .file(URL(fileURLWithPath: "/out/a--balanced-web.webp")), recipe: recipe,
            before: MediaStats(bytes: 2_009_246, width: 1080, height: 1920),
            after: MediaStats(bytes: 205_844, width: 1080, height: 1920, qualityScore: 80.1784),
            status: status, elapsed: 1.1234, context: "row-1", outputType: .webP)
    }

    func testResultCarriesTheDocumentedKeys() throws {
        let o = ReceiptJSON.result(sample())
        XCTAssertEqual(o["type"] as? String, "result")
        XCTAssertEqual(o["status"] as? String, "optimized")
        XCTAssertEqual(o["input"] as? String, "/in/a.png")
        XCTAssertEqual(o["output"] as? String, "/out/a--balanced-web.webp")
        XCTAssertEqual(o["mime"] as? String, "image/webp")
        XCTAssertEqual(o["saved_bytes"] as? Int, 2_009_246 - 205_844)
        XCTAssertEqual(o["quality_floor"] as? Double, 80)
        XCTAssertEqual(o["stripped_metadata"] as? Bool, true)
        let after = try XCTUnwrap(o["after"] as? [String: Any])
        XCTAssertEqual(after["bytes"] as? Int, 205_844)
    }

    func testLinesAreSortedStableAndDecimalClean() throws {
        let line = try XCTUnwrap(ReceiptJSON.line(ReceiptJSON.result(sample())))
        XCTAssertTrue(line.contains("\"ssimu2\":80.18"), line)
        XCTAssertFalse(line.contains("80.17840000"), "no binary-float noise")
        XCTAssertTrue(line.contains("\"elapsed_s\":1.12"))
        XCTAssertTrue(line.hasPrefix("{\"after\":{\"bytes\":205844"), "sorted keys, top to bottom: \(line.prefix(40))")
        // Round-trips as JSON, one object per line.
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["type"] as? String, "result")
        XCTAssertFalse(line.contains("\n"))
    }

    func testFailuresCarryTheirReasonAndCancelledReadsAsSuch() {
        let o = ReceiptJSON.result(sample(status: .failed("cancelled")))
        XCTAssertEqual(o["status"] as? String, "failed")
        XCTAssertEqual(o["reason"] as? String, "cancelled")
        let k = ReceiptJSON.result(sample(status: .skipped("re-encode ≥ source")))
        XCTAssertEqual(k["status"] as? String, "skipped")
        XCTAssertEqual(k["reason"] as? String, "re-encode ≥ source")
    }

    func testSummaryMatchesTheCLIShape() throws {
        let s = Summary([sample(), sample(status: .skipped("kept")), sample(status: .failed("x"))])
        let o = ReceiptJSON.summary(s)
        XCTAssertEqual(o["type"] as? String, "summary")
        XCTAssertEqual(o["count"] as? Int, 3)
        XCTAssertEqual(o["optimized"] as? Int, 1)
        XCTAssertEqual(o["skipped"] as? Int, 1)
        XCTAssertEqual(o["failed"] as? Int, 1)
        XCTAssertEqual(o["bytes_in"] as? Int, 3 * 2_009_246)
        // skipped/failed count at source size in the aggregate — never a trial encode's size
        XCTAssertEqual(o["bytes_out"] as? Int, 205_844 + 2 * 2_009_246)
        XCTAssertNotNil(ReceiptJSON.line(o))
    }

    /// BRIDGE-061 / AB-T-0014: a video score is a percentile over a sample, and the receipt has to say
    /// so key for key. The primary's numbers are the tp_layersb corpus receipt, re-verified against
    /// media-bridge 0.39.1 (2026-09-28) by re-scoring the delivered file: p10 80.14 cleared the floor
    /// over 25 of 353 frames while the worst frame, 76.43, did not — both defensible, not the same claim.
    func testVideoAggregationRidesTheReceiptKeyForKey() throws {
        var recipe = AppliedRecipe()
        recipe.codec = "HEVC"; recipe.qualityFloor = 80
        recipe.secondaryFloor = 70; recipe.secondaryOutcome = "delivered"
        let primary = MediaStats.QualityAggregation(percentile: 10, minimum: 76.4312, mean: 82.8791,
                                                    framesScored: 25, frameCount: 353)
        let harvested = SecondaryResult(
            output: .file(URL(fileURLWithPath: "/out/clip--70.mp4")), floor: 70, searchFloor: 80,
            bytes: 1_402_113, width: 1080, height: 1920, score: 72.3149,
            aggregation: .init(percentile: 10, minimum: 68.0221, mean: 75.4968,
                               framesScored: 13, frameCount: 353))
        let r = OptimizeResult(
            input: URL(fileURLWithPath: "/in/clip.mp4"), kind: .video,
            output: .file(URL(fileURLWithPath: "/out/clip.mp4")), recipe: recipe,
            before: MediaStats(bytes: 3_781_559, width: 1080, height: 1920),
            after: MediaStats(bytes: 2_960_172, width: 1080, height: 1920,
                              qualityScore: 80.1413, qualityAggregation: primary),
            status: .optimized, elapsed: 8.91, outputType: .mpeg4Movie, secondary: harvested)
        let o = ReceiptJSON.result(r)

        let after = try XCTUnwrap(o["after"] as? [String: Any])
        XCTAssertEqual(after["ssimu2"] as? Decimal, Decimal(string: "80.14"),
                       "the score beside the aggregation is the percentile the floor gated on, not the mean")
        let a = try XCTUnwrap(after["aggregation"] as? [String: Any], "a video score must say it is a reduction")
        XCTAssertEqual(Set(a.keys), ["percentile", "min", "mean", "frames_scored", "frame_count"])
        XCTAssertEqual(a["percentile"] as? Int, 10)
        XCTAssertEqual(a["min"] as? Decimal, Decimal(string: "76.43"), "the worst frame is printed, below the floor or not")
        XCTAssertEqual(a["mean"] as? Decimal, Decimal(string: "82.88"))
        XCTAssertEqual(a["frames_scored"] as? Int, 25)
        XCTAssertEqual(a["frame_count"] as? Int, 353, "the clip's own length — 25 of 353 says this was a sample")
        XCTAssertNil((o["before"] as? [String: Any])?["aggregation"], "the source was never scored")

        // The harvested rendition reports its OWN reduction on the same terms — never the primary's.
        let sec = try XCTUnwrap(o["secondary"] as? [String: Any])
        XCTAssertEqual(sec["ssimu2"] as? Decimal, Decimal(string: "72.31"))
        let s = try XCTUnwrap(sec["aggregation"] as? [String: Any])
        XCTAssertEqual(Set(s.keys), Set(a.keys), "one aggregation shape, wherever it appears")
        XCTAssertEqual(s["percentile"] as? Int, 10)
        XCTAssertEqual(s["min"] as? Decimal, Decimal(string: "68.02"))
        XCTAssertEqual(s["mean"] as? Decimal, Decimal(string: "75.50"))
        XCTAssertEqual(s["frames_scored"] as? Int, 13)
        XCTAssertEqual(s["frame_count"] as? Int, 353)

        // And on the wire: sorted keys and decimal-clean, exactly as a host's manifest stores it.
        let line = try XCTUnwrap(ReceiptJSON.line(o))
        XCTAssertTrue(line.contains(
            #""aggregation":{"frame_count":353,"frames_scored":25,"mean":82.88,"min":76.43,"percentile":10}"#), line)
        XCTAssertTrue(line.contains(#""ssimu2":80.14"#), line)
    }

    /// nil-for-stills is load-bearing: the presence of `aggregation` is what marks a score as a reduction.
    func testAStillScoreCarriesNoAggregation() throws {
        let after = try XCTUnwrap(ReceiptJSON.result(sample())["after"] as? [String: Any])
        XCTAssertNotNil(after["ssimu2"])
        XCTAssertNil(after["aggregation"], "a still's score IS its one frame")
    }
}
