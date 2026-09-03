import XCTest
@testable import ForgeOptimizerKit

/// The class-ratchet's stash-and-restore invariant: *a stricter attempt must never cost the result
/// already in hand.* The ratchet moves a good deliverable aside so the raised-floor re-run has
/// somewhere to write, which means that between the stash and the restore the output URL holds
/// nothing — so every exit from the attempt has to put something back.
///
/// The throwing exit is the one that escaped (found 2026-08-16): an encode error propagated straight
/// out of `optimizeVideo`, leaving a perfectly good deliverable stranded in the stash, the item
/// reporting `.failed`, and a `.forge-ratchet-*.tmp` orphaned beside the user's output. Every test
/// here asserts BOTH halves of the guarantee — the deliverable survives, and no stash outlives the
/// call — because the original bug failed both.
final class RatchetStashTests: XCTestCase {

    private struct EncodeFailure: Error {}

    private var dir: URL!
    private var deliverable: URL!
    private let original = Data("the result already in hand".utf8)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratchet-stash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        deliverable = dir.appendingPathComponent("out.mp4")
        try original.write(to: deliverable)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func strayStashes() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".forge-ratchet-") }
    }

    private func assertDeliverable(is expected: Data, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: deliverable.path),
                      "the output URL must hold a deliverable — \(what)", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: deliverable), expected,
                       "wrong deliverable — \(what)", file: file, line: line)
        XCTAssertEqual(try strayStashes(), [],
                       "a .forge-ratchet-*.tmp outlived the call — \(what)", file: file, line: line)
    }

    // MARK: - the regression

    func testThrowingAttemptRestoresTheDeliverableAndReturnsNil() async throws {
        let out = deliverable!
        let kept = try await RatchetStash.attemptReplacing(out, accept: { (_: Int) in true }) {
            // The re-run got as far as a partial write, then failed — the encode-error shape.
            try Data("partial garbage".utf8).write(to: out)
            throw EncodeFailure()
        }
        XCTAssertNil(kept, "a failed attempt keeps the original rather than replacing it")
        try assertDeliverable(is: original, "a throwing re-run must cost nothing")
    }

    func testCancellationPropagatesButStillRestoresTheDeliverable() async throws {
        let out = deliverable!
        do {
            _ = try await RatchetStash.attemptReplacing(out, accept: { (_: Int) in true }) {
                try Data("partial garbage".utf8).write(to: out)
                throw CancellationError()
            }
            XCTFail("cancellation must propagate — a cancelled run may not quietly produce a result")
        } catch is CancellationError {
            // expected
        }
        try assertDeliverable(is: original, "cancellation must not eat the deliverable either")
    }

    // MARK: - the paths that already worked (pinned so the extraction didn't move them)

    func testDecliningAttemptRestoresTheOriginal() async throws {
        let out = deliverable!
        let kept = try await RatchetStash.attemptReplacing(out, accept: { (ok: Bool) in ok }) {
            try Data("a worse encode".utf8).write(to: out)
            return false                        // delivered, but did not meet the raised target
        }
        XCTAssertNil(kept, "a declined attempt keeps the original")
        try assertDeliverable(is: original, "a non-delivering re-run must cost nothing")
    }

    func testAcceptedAttemptReplacesTheDeliverableAndClearsTheStash() async throws {
        let out = deliverable!
        let better = Data("the raised-floor encode".utf8)
        let kept = try await RatchetStash.attemptReplacing(out, accept: { (ok: Bool) in ok }) {
            try better.write(to: out)
            return true
        }
        XCTAssertEqual(kept, true, "an accepted attempt is returned to the caller")
        try assertDeliverable(is: better, "the ratchet's whole point: the stricter result wins")
    }

    // MARK: - companions: a run's outputs are a matched set

    /// The secondary rendition (AB-A-0059) ships beside the primary and comes from the SAME search.
    /// A declined re-run must therefore put back BOTH — restoring the primary while leaving the
    /// re-run's rendition in place would hand the caller a pair that never existed together
    /// (different floor regime, different reference, possibly different resolution) under one
    /// receipt.
    func testDecliningAttemptRestoresCompanionsToo() async throws {
        let out = deliverable!
        let companion = dir.appendingPathComponent("out.secondary.mp4")
        let originalCompanion = Data("the rendition from the first search".utf8)
        try originalCompanion.write(to: companion)

        let kept = try await RatchetStash.attemptReplacing(
            out, companions: [companion], accept: { (ok: Bool) in ok }
        ) {
            try Data("a worse encode".utf8).write(to: out)
            try Data("the re-run's rendition".utf8).write(to: companion)
            return false
        }

        XCTAssertNil(kept)
        try assertDeliverable(is: original, "the primary must be the first search's")
        XCTAssertEqual(try Data(contentsOf: companion), originalCompanion,
                       "the rendition beside it must be the SAME search's, not the abandoned one's")
    }

    /// The other half: a re-run that IS accepted keeps its own pair, and no stash survives.
    func testAcceptedAttemptKeepsItsOwnCompanion() async throws {
        let out = deliverable!
        let companion = dir.appendingPathComponent("out.secondary.mp4")
        try Data("the rendition from the first search".utf8).write(to: companion)
        let betterCompanion = Data("the raised-floor search's rendition".utf8)

        let kept = try await RatchetStash.attemptReplacing(
            out, companions: [companion], accept: { (ok: Bool) in ok }
        ) {
            try Data("the raised-floor encode".utf8).write(to: out)
            try betterCompanion.write(to: companion)
            return true
        }

        XCTAssertEqual(kept, true)
        XCTAssertEqual(try Data(contentsOf: companion), betterCompanion)
        XCTAssertEqual(try strayStashes(), [], "no companion stash may outlive the call")
    }

    /// When the original run produced NO rendition, a declined re-run's rendition must be REMOVED,
    /// not left behind. Otherwise the file on disk would be the only record of a search whose
    /// result was thrown away — and the receipt, which describes the kept original, would not
    /// mention it at all.
    func testDecliningAttemptRemovesACompanionTheOriginalNeverHad() async throws {
        let out = deliverable!
        let companion = dir.appendingPathComponent("out.secondary.mp4")   // deliberately absent

        let kept = try await RatchetStash.attemptReplacing(
            out, companions: [companion], accept: { (ok: Bool) in ok }
        ) {
            try Data("a worse encode".utf8).write(to: out)
            try Data("a rendition with no counterpart".utf8).write(to: companion)
            return false
        }

        XCTAssertNil(kept)
        try assertDeliverable(is: original, "the original still stands")
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.path),
                       "an orphan rendition from a discarded search must not survive it")
    }

    func testStashFailureThrowsBeforeAnythingIsRisked() async throws {
        let missing = dir.appendingPathComponent("never-written.mp4")
        var attempted = false
        do {
            _ = try await RatchetStash.attemptReplacing(missing, accept: { (_: Int) in true }) {
                attempted = true
                return 1
            }
            XCTFail("stashing a deliverable that does not exist must throw")
        } catch is EncodeFailure {
            XCTFail("the failure must come from the stash move, not the attempt")
        } catch {
            // expected — the FileManager move failed
        }
        XCTAssertFalse(attempted, "the attempt must not run when the stash could not be taken")
        XCTAssertEqual(try strayStashes(), [], "a failed stash leaves nothing behind")
    }
}
