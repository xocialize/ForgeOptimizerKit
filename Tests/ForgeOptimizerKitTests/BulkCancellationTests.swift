import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import ForgeOptimizerKit

/// The two stop levers of a bulk run, and the promise behind each: `BulkControl.stop()` admits
/// nothing more and lets the items already running finish; cancelling the consuming task stops
/// now and cancels the producer with it, so no work continues behind an abandoned stream.
final class BulkCancellationTests: XCTestCase {

    private var tmp: URL!
    private let width = 3

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("out"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    /// Photo-like 256² stills: a real web race per item (PNG + a JPEG floor search), ~0.2 s each,
    /// so a cancel has passes to land between.
    private func makeStills(_ n: Int) throws -> [OptimizeRequest] {
        let image = photoLikeStill(256)
        return try (0..<n).map { i in
            let src = tmp.appendingPathComponent("still-\(i).png")
            let dst = CGImageDestinationCreateWithURL(src as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, image, nil); CGImageDestinationFinalize(dst)
            return OptimizeRequest(input: src, output: tmp.appendingPathComponent("out/still-\(i)"),
                                   options: Options(), context: "\(i)")
        }
    }

    private func photoLikeStill(_ side: Int) -> CGImage {
        // The context owns its pixels: the image may share them copy-on-write, so they must outlive this call.
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 0x9E3779B9
        func grain() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(Int32(truncatingIfNeeded: seed >> 8) % 13) - 6 }
        for y in 0..<side { for x in 0..<side {
            let fx = Double(x) / Double(side), fy = Double(y) / Double(side)
            let l1 = 110 + 70 * sin(fx * 4.1 + 0.6) * cos(fy * 2.9 + 1.1), l2 = 40 * sin((fx + fy) * 6.3)
            let i = y * ctx.bytesPerRow + x * 4
            bytes[i] = UInt8(clamping: Int(l1 + l2 * 0.7 + grain())); bytes[i + 1] = UInt8(clamping: Int(l1 * 0.9 + l2 + grain()))
            bytes[i + 2] = UInt8(clamping: Int(l1 * 1.1 + l2 * 0.4 + grain())); bytes[i + 3] = 255
        } }
        return ctx.makeImage()!
    }

    private func outputs() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("out").path).count
    }

    /// stop() after the first receipt: the items already admitted finish and deliver, and nothing
    /// more is admitted. How many get in before the stop lands is the consumer's scheduling, not
    /// the promise — yields never wait for the consumer, so a late one lets the producer keep
    /// filling slots — and a bound on it turned CI red (run 36455208268: 6 receipts against 5).
    /// So the control reports what the stop landed on, and the run must deliver exactly that.
    /// Twelve identical items finish in clusters, so the stop tends to land while the producer is
    /// still admitting: the interleaving the gate has to get right.
    func testStopAfterCurrentAdmitsNothingMore() async throws {
        try await assertStopDeliversExactlyWhatItAdmitted(width: width)
    }

    /// The serial path (width 1 — what an injected enhancer forces) runs the same gate.
    func testStopAfterCurrentAdmitsNothingMoreOnTheSerialPath() async throws {
        try await assertStopDeliversExactlyWhatItAdmitted(width: 1)
    }

    private func assertStopDeliversExactlyWhatItAdmitted(width: Int) async throws {
        let requests = try makeStills(12)
        let forge = ForgeOptimizer(bulkConcurrency: width)
        let control = BulkControl()
        var received: [OptimizeResult] = []
        for await r in forge.webOptimize(requests, control: control) {
            received.append(r)
            if received.count == 1 { control.stop() }
        }
        XCTAssertGreaterThanOrEqual(received.count, 1)
        let admitted = try XCTUnwrap(control.admittedAtStop, "stop() records the admissions it landed on")
        XCTAssertEqual(received.count, admitted,
                       "stop admits nothing more: \(received.count) receipts, \(admitted) admitted when the stop landed")
        XCTAssertTrue(received.allSatisfy { if case .optimized = $0.status { return true }; return false },
                      "the items that ran, ran to completion — a stop cancels nothing")
        XCTAssertEqual(received.map(\.context), (0..<received.count).map { "\($0)" }, "still in submission order")
        XCTAssertEqual(try outputs(), received.count, "every receipt has its file and nothing else was written")
    }

    /// The gate both runners call once per item: an admission either precedes `stop()` and is in
    /// `admittedAtStop`, or is refused — also when admissions race the stop from many threads,
    /// which is what makes that count exact. A second stop() moves nothing.
    func testTheGateCountsExactlyTheAdmissionsBeforeTheStop() {
        XCTAssertNil(BulkControl().admittedAtStop, "no stop, nothing to report")
        let control = BulkControl()
        let admitted = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 20_000) { i in
            if i == 10_000 { control.stop() }
            if control.admit() { admitted.withLock { $0 += 1 } }
        }
        let got = admitted.withLock { $0 }
        XCTAssertEqual(control.admittedAtStop, got)
        XCTAssertFalse(control.admit(), "a stopped control admits nothing")
        control.stop()
        XCTAssertEqual(control.admittedAtStop, got, "stop() is idempotent: the first stop's count stands")
    }

    /// Cancelling the consumer after the first receipt ends the stream at once and cancels the
    /// producer: after a grace period no more outputs appear — the other nine never ran.
    func testCancellingTheConsumerStopsTheProducer() async throws {
        let requests = try makeStills(12)
        let forge = ForgeOptimizer(bulkConcurrency: width)
        let consumer = Task { () -> Int in
            var n = 0
            for await _ in forge.webOptimize(requests) {
                n += 1
                if n == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return n
        }
        let received = await consumer.value
        XCTAssertGreaterThanOrEqual(received, 1)
        try await Task.sleep(for: .seconds(1.5))
        let after = try outputs()
        XCTAssertLessThanOrEqual(after, 1 + width + 1, "the producer stopped with the consumer: \(after) outputs")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(try outputs(), after, "nothing keeps running behind an abandoned stream")
    }

    /// Breaking out of the loop (abandoning the stream) is the same as cancelling it.
    func testAbandoningTheStreamStopsTheProducer() async throws {
        let requests = try makeStills(12)
        let forge = ForgeOptimizer(bulkConcurrency: width)
        var n = 0
        for await _ in forge.webOptimize(requests) { n += 1; if n == 1 { break } }
        try await Task.sleep(for: .seconds(1.5))
        let after = try outputs()
        XCTAssertLessThanOrEqual(after, 1 + width + 1, "\(after) outputs after abandoning the stream")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(try outputs(), after)
    }

    /// With neither lever pulled, nothing changed: twelve receipts in order.
    func testNoLeverMeansTheWholeBatch() async throws {
        let requests = try makeStills(6)
        let forge = ForgeOptimizer(bulkConcurrency: width)
        var contexts: [String?] = []
        for await r in forge.webOptimize(requests, control: BulkControl()) { contexts.append(r.context) }
        XCTAssertEqual(contexts, (0..<6).map { "\($0)" })
        XCTAssertEqual(try outputs(), 6)
    }
}
