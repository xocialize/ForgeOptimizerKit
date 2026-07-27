import XCTest
@testable import ForgeOptimizerKit

/// BRIDGE-062. The receipt used to report `options.upscale` — what the caller *asked for*. That is
/// accurate only while every model honours every request, which is a property of today's models rather
/// than of the code.
///
/// BRIDGE-040 is the case that proves it: a fixed-4× model asked for 2× produced 4× pixels while the
/// receipt said 2×. These lock the fix by driving the exact divergences a request-based tag cannot see.
final class UpscaleHonestyTests: XCTestCase {

    private func recipe(from before: Int, to after: Int, requested: UpscaleFactor) -> AppliedRecipe {
        var r = AppliedRecipe()
        r.setUpscale(measuredFrom: before, to: after, requested: requested)
        return r
    }

    func testHonouredRequestReportsTheFactorWithNoNoise() {
        let r = recipe(from: 512, to: 1024, requested: .x2)
        XCTAssertEqual(r.upscaled, 2)
        XCTAssertNil(r.upscaleRequested, "no divergence to report when the model did as asked")
        XCTAssertTrue(r.description.contains("upscale×2"))
        XCTAssertFalse(r.description.contains("asked"))
    }

    /// The original BRIDGE-040 defect: asked 2×, got 4×. The receipt must say 4 and show the divergence.
    func testFixedFourTimesModelAskedForTwoReportsFourAndSaysSo() {
        let r = recipe(from: 512, to: 2048, requested: .x2)
        XCTAssertEqual(r.upscaled, 4, "must report the pixels that exist, not the request")
        XCTAssertEqual(r.upscaleRequested, 2)
        XCTAssertTrue(r.description.contains("upscale×4 (asked ×2)"), r.description)
    }

    /// The inverse lie: an upscale was requested and did not happen. Reporting the request here would
    /// claim an enhancement that is not in the file.
    func testRequestedButNotAppliedReportsNoUpscale() {
        let r = recipe(from: 512, to: 512, requested: .x2)
        XCTAssertNil(r.upscaled, "no upscale in the pixels means no upscale in the receipt")
        XCTAssertEqual(r.upscaleRequested, 2, "but the unmet request is still surfaced")
        XCTAssertFalse(r.description.contains("upscale×"), r.description)
    }

    func testNoUpscaleRequestedAndNoneApplied() {
        let r = recipe(from: 512, to: 512, requested: .none)
        XCTAssertNil(r.upscaled)
        XCTAssertNil(r.upscaleRequested)
    }

    /// Degenerate input must not fabricate a factor.
    func testZeroWidthsDoNotInventAnUpscale() {
        XCTAssertNil(recipe(from: 0, to: 1024, requested: .x2).upscaled)
        XCTAssertNil(recipe(from: 512, to: 0, requested: .x2).upscaled)
    }

    /// Rounding tolerance: an encoder nudging 1024→1026 for macroblock alignment is not a 1× upscale
    /// claim, and a real 2× that lands a pixel off is still 2×.
    func testToleratesAlignmentNudgesWithoutMisreporting() {
        XCTAssertNil(recipe(from: 1024, to: 1026, requested: .none).upscaled)
        XCTAssertEqual(recipe(from: 512, to: 1023, requested: .x2).upscaled, 2)
    }
}
