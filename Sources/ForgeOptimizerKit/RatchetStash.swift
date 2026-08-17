import Foundation
import MediaMetrics

/// The class-ratchet's stash-and-restore protocol, lifted out of `optimizeVideo` so the invariant it
/// exists to hold is pinned by a test rather than by a careful reading of the control flow:
///
/// > A stricter attempt must never cost the result already in hand.
///
/// The ratchet re-runs the search at a raised floor *on top of* a deliverable that already cleared
/// the preset floor. That deliverable occupies the output URL, so the re-run must move it aside to
/// have somewhere to write — and from that moment the output URL holds nothing until one of the two
/// results is put back. Every exit therefore has to be accounted for, including the throwing one
/// that originally was not: a re-run that threw left the good deliverable stranded in the stash,
/// reported the item `.failed`, and abandoned a `.forge-ratchet-*.tmp` beside the user's output.
enum RatchetStash {

    /// Runs `attempt` with the existing deliverable at `deliverable` stashed aside, then leaves
    /// `deliverable` holding **either** the attempt's replacement (when `accept` returns true) **or**
    /// the original — never nothing, and never a leftover stash file, on any exit path.
    ///
    /// - Parameters:
    ///   - deliverable: the URL holding the result already in hand. Must exist.
    ///   - accept: whether the attempt's result is good enough to replace the original.
    ///   - attempt: the stricter attempt, which writes its own output to `deliverable`.
    /// - Returns: the attempt's result when it was accepted; `nil` when the original was kept —
    ///   because the attempt declined to deliver, or because it threw.
    /// - Throws: from the initial stash move (nothing has been risked yet at that point, so the
    ///   caller's own `throws` is the honest answer), or a cancellation raised by `attempt` —
    ///   re-thrown *after* the original is restored. A cancelled run must not quietly produce a
    ///   result, but it must not eat one either.
    static func attemptReplacing<T>(
        _ deliverable: URL,
        accept: (T) -> Bool,
        _ attempt: () async throws -> T
    ) async throws -> T? {
        let stash = deliverable.deletingLastPathComponent()
            .appendingPathComponent(".forge-ratchet-\(UUID().uuidString).tmp")
        try FileManager.default.moveItem(at: deliverable, to: stash)

        func restore() {
            try? FileManager.default.removeItem(at: deliverable)   // a partial write never survives
            do { try FileManager.default.moveItem(at: stash, to: deliverable) }
            catch { MediaMetrics.event("kit.ratchet.restore_failed", attrs: ["error": "\(error)"]) }
        }

        let result: T
        do {
            result = try await attempt()
        } catch {
            // A throwing stricter attempt costs exactly what a non-delivering one costs: nothing.
            restore()
            MediaMetrics.event("kit.ratchet.failed", attrs: ["error": "\(error)"])
            if error is CancellationError || Task.isCancelled { throw error }
            return nil
        }

        guard accept(result) else { restore(); return nil }
        try? FileManager.default.removeItem(at: stash)
        return result
    }
}
