import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        var seed: UInt32 = 0x9E3779B9
        func grain() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(Int32(truncatingIfNeeded: seed >> 8) % 13) - 6 }
        for y in 0..<256 { for x in 0..<256 {
            let fx = Double(x) / 256, fy = Double(y) / 256
            let l1 = 110 + 70 * sin(fx * 4.1 + 0.6) * cos(fy * 2.9 + 1.1), l2 = 40 * sin((fx + fy) * 6.3)
            let i = (y * 256 + x) * 4
            bytes[i] = UInt8(clamping: Int(l1 + l2 * 0.7 + grain())); bytes[i + 1] = UInt8(clamping: Int(l1 * 0.9 + l2 + grain()))
            bytes[i + 2] = UInt8(clamping: Int(l1 * 1.1 + l2 * 0.4 + grain())); bytes[i + 3] = 255
        } }
        let ctx = CGContext(data: &bytes, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = ctx.makeImage()!
        return try (0..<n).map { i in
            let src = tmp.appendingPathComponent("still-\(i).png")
            let dst = CGImageDestinationCreateWithURL(src as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, image, nil); CGImageDestinationFinalize(dst)
            return OptimizeRequest(input: src, output: tmp.appendingPathComponent("out/still-\(i)"),
                                   options: Options(), context: "\(i)")
        }
    }

    private func outputs() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("out").path).count
    }

    /// stop() after the first receipt: the items in the group finish and deliver, nothing more is
    /// admitted. Bound: the first, up to `width` in flight, plus one the producer may have admitted
    /// before the stop landed (yields never wait for the consumer).
    func testStopAfterCurrentAdmitsNothingMore() async throws {
        let requests = try makeStills(12)
        let forge = ForgeOptimizer(bulkConcurrency: width)
        let control = BulkControl()
        var received: [OptimizeResult] = []
        for await r in forge.webOptimize(requests, control: control) {
            received.append(r)
            if received.count == 1 { control.stop() }
        }
        XCTAssertGreaterThanOrEqual(received.count, 1)
        XCTAssertLessThanOrEqual(received.count, 1 + width + 1, "stop admits nothing more: \(received.count) receipts")
        XCTAssertTrue(received.allSatisfy { if case .optimized = $0.status { return true }; return false },
                      "the items that ran, ran to completion — a stop cancels nothing")
        XCTAssertEqual(received.map(\.context), (0..<received.count).map { "\($0)" }, "still in submission order")
        XCTAssertEqual(try outputs(), received.count, "every receipt has its file and nothing else was written")
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
