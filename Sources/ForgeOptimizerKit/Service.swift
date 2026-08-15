import Foundation

/// Single-flight, busy-signalling front door for headless / pipeline use (Marquee, the glue layer).
/// Forge processes **one run at a time** and **rejects** a concurrent submission with `ForgeError.busy` —
/// the host owns any queueing/scheduling (a deliberate boundary: Forge stays a stateless optimizer, the
/// host decides what to do when it's busy). `state` is observable so the host can disable its action or
/// show "processing".
///
/// Lifecycle: `optimize` flips to `.processing` synchronously (so a racing caller sees `.busy` immediately),
/// returns the receipt stream, and flips back to `.idle` when that stream is fully drained. A host that
/// abandons the stream without draining leaves the service busy — drain it (breaking the `for await`
/// cancels the run and releases the lock).
public actor ForgeOptimizerService {
    public enum State: Sendable { case idle, processing }

    public private(set) var state: State = .idle
    public var isBusy: Bool { state == .processing }

    private let optimizer: ForgeOptimizer

    public init(enhancer: (any ImageEnhancer)? = nil,
                hintProvider: (any ContentHintProvider)? = nil) {
        self.optimizer = ForgeOptimizer(enhancer: enhancer, hintProvider: hintProvider)
    }

    /// Run a batch of pipeline requests. Throws `ForgeError.busy` if a run is already in progress.
    /// `progress` is the stubbed handler (see `ForgeOptimizer.optimize(_:progress:)`).
    public func optimize(_ requests: [OptimizeRequest],
                         progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        throws -> AsyncStream<OptimizeResult> {
        guard state == .idle else { throw ForgeError.busy }
        state = .processing
        return locked(optimizer.optimize(requests, progress: progress))
    }

    /// `optimize` with web-universal outputs (PNG stills, H.264 + AAC mp4 video) — see
    /// `ForgeOptimizer.webOptimize`. Same single-flight lock as `optimize` (one run at a time
    /// across both verbs).
    public func webOptimize(_ requests: [OptimizeRequest],
                            progress: (@Sendable (OptimizeProgress) -> Void)? = nil)
        throws -> AsyncStream<OptimizeResult> {
        guard state == .idle else { throw ForgeError.busy }
        state = .processing
        return locked(optimizer.webOptimize(requests, progress: progress))
    }

    private func locked(_ upstream: AsyncStream<OptimizeResult>) -> AsyncStream<OptimizeResult> {
        AsyncStream { continuation in
            // This Task inherits the actor's isolation, so it serialises with `state` access and a racing
            // caller sees `.processing` (→ `.busy`) until the stream is drained and `release()` runs.
            Task {
                for await r in upstream { continuation.yield(r) }
                continuation.finish()
                self.release()
            }
        }
    }

    private func release() { state = .idle }
}
