import Foundation

/// Admission control for a bulk run — **"stop after the current items"** without cancelling them.
///
/// A bulk stream has two stop levers, and they mean different things:
///
/// - `BulkControl.stop()` — every item already running finishes and delivers; nothing more is
///   admitted; the stream ends when the in-flight items have. Nothing written is abandoned.
/// - cancelling the consuming task — **"stop now"**: in-flight items abort at their next cancellation
///   point (a video at its next encode boundary, a still at its next search pass — media-bridge
///   ≥ 0.39.1) and nothing more is admitted. The stream ends at once for the consumer; the producer
///   is cancelled with it (`onTermination`), so no work continues behind an abandoned stream.
///
/// A host wires "Stop after current" to `stop()` and "Stop now" to `Task.cancel()`. `stop()` is
/// one-way and idempotent; a control belongs to one call.
public final class BulkControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var admitted = 0
    private var admittedWhenStopped: Int?

    public init() {}

    /// Admit nothing more. Items already running finish and deliver.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        admittedWhenStopped = admitted
    }

    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// How many items the run had admitted when `stop()` first landed; `nil` until it has. Each of
    /// them finishes and delivers and none is admitted after, so a stopped run read to its end
    /// delivers exactly this many receipts: `admittedAtStop - delivered` are still to come.
    /// (Cancelling as well ends the stream early, so fewer may arrive.)
    public var admittedAtStop: Int? { lock.lock(); defer { lock.unlock() }; return admittedWhenStopped }

    /// The run's per-item gate: counts one admission and returns true, or returns false once
    /// stopped. The check and the count are one step under the lock `stop()` takes, so an item is
    /// either admitted before the stop — and counted in `admittedAtStop` — or refused.
    func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        admitted += 1
        return true
    }
}
