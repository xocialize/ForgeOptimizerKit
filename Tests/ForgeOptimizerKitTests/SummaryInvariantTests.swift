import XCTest
@testable import ForgeOptimizerKit

/// The aggregate counts savings ONLY from deliveries — the structural half of the skip-aggregation
/// fix (ported from its worktree branch, which predates the parity rewrite). A skipped/failed item
/// keeps the original, so it contributes zero savings even when its `after` (adversarially)
/// carries a stale trial-encode size or a zero — the two shapes that once read as "saved 50%" /
/// "saved 100%" in the run summary.
final class SummaryInvariantTests: XCTestCase {

    private func result(_ status: Status, before: Int, after: Int) -> OptimizeResult {
        OptimizeResult(input: URL(fileURLWithPath: "/in.mov"), kind: .video, output: .none,
                       recipe: AppliedRecipe(),
                       before: MediaStats(bytes: before, width: 0, height: 0),
                       after: MediaStats(bytes: after, width: 0, height: 0),
                       status: status, elapsed: 0)
    }

    func testSummaryCountsNoSavingsForSkippedOrFailed() {
        let skipped = Summary([result(.skipped("couldn't reach the floor"), before: 1000, after: 500)])
        XCTAssertEqual(skipped.bytesOut, 1000, "the kept original is the after-state")
        XCTAssertEqual(skipped.savedFraction, 0, "a skip saves nothing")

        let failed = Summary([result(.failed("boom"), before: 1000, after: 0)])
        XCTAssertEqual(failed.bytesOut, 1000)
        XCTAssertEqual(failed.savedFraction, 0, "a failure saves nothing")

        let mixed = Summary([result(.optimized, before: 1000, after: 400),
                             result(.skipped("floor"), before: 1000, after: 500)])
        XCTAssertEqual(mixed.bytesIn, 2000)
        XCTAssertEqual(mixed.bytesOut, 1400, "only the delivery's output counts")
        XCTAssertEqual(mixed.savedFraction, 0.3, accuracy: 0.0001)
    }
}
