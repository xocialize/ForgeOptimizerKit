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

    public init() {}

    /// Admit nothing more. Items already running finish and deliver.
    public func stop() { lock.lock(); stopped = true; lock.unlock() }

    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
