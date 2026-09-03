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
    ///   - companions: further URLs the attempt also writes, which belong to the SAME result and
    ///     must be restored or discarded WITH it — today the secondary rendition. Each is stashed
    ///     only if it exists, and on a restore a companion the original run did not produce is
    ///     removed rather than left behind: a run's outputs are a matched set (same floor regime,
    ///     same reference, same resolution), and mixing one run's primary with another run's
    ///     companion would make the receipt describe a pair that never existed together.
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
        companions: [URL] = [],
        accept: (T) -> Bool,
        _ attempt: () async throws -> T
    ) async throws -> T? {
        func stashURL(beside url: URL) -> URL {
            url.deletingLastPathComponent()
                .appendingPathComponent(".forge-ratchet-\(UUID().uuidString).tmp")
        }
        let stash = stashURL(beside: deliverable)
        try FileManager.default.moveItem(at: deliverable, to: stash)
        // Companions are stashed AFTER the deliverable: the move above is the only one allowed to
        // throw out of here (nothing has been risked yet), and a companion that cannot be moved
        // must not strand the deliverable in its stash.
        var companionStash: [(live: URL, stashed: URL?)] = []
        for c in companions {
            guard FileManager.default.fileExists(atPath: c.path) else {
                companionStash.append((c, nil))   // nothing to keep — but still ours to clean up
                continue
            }
            let s = stashURL(beside: c)
            if (try? FileManager.default.moveItem(at: c, to: s)) != nil {
                companionStash.append((c, s))
            } else {
                companionStash.append((c, nil))
                MediaMetrics.event("kit.ratchet.companion_stash_failed", attrs: ["url": c.lastPathComponent])
            }
        }

        func restore() {
            try? FileManager.default.removeItem(at: deliverable)   // a partial write never survives
            do { try FileManager.default.moveItem(at: stash, to: deliverable) }
            catch { MediaMetrics.event("kit.ratchet.restore_failed", attrs: ["error": "\(error)"]) }
            for (live, stashed) in companionStash {
                try? FileManager.default.removeItem(at: live)      // whatever the attempt wrote goes
                guard let stashed else { continue }                // the original had none → none stands
                do { try FileManager.default.moveItem(at: stashed, to: live) }
                catch { MediaMetrics.event("kit.ratchet.restore_failed", attrs: ["error": "\(error)"]) }
            }
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
        for (_, stashed) in companionStash { if let stashed { try? FileManager.default.removeItem(at: stashed) } }
        return result
    }
}
