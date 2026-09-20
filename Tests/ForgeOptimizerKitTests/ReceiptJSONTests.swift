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
}
