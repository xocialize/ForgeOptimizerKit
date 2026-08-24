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
