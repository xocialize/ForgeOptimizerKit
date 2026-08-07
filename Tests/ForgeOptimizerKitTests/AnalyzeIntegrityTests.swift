import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo
@testable import ForgeOptimizerKit

/// `analyze` integrity: structural verification rides every analysis by default, the deep tier is
/// opt-in, and — the production-facing contract change — a corrupt or unreadable file **yields a
/// diagnostic `Analysis` instead of vanishing from the stream** (the old `try?` swallow made
/// corruption look like absence).
final class AnalyzeIntegrityTests: XCTestCase {

    private let forge = ForgeOptimizer()

    func testAnalyzeCarriesIntactIntegrityByDefault() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("ok.png")
        try writePNG(makeImage(64), to: src)

        var results: [Analysis] = []
        for await a in forge.analyze(.url(src)) { results.append(a) }
        let a = try XCTUnwrap(results.first)
        XCTAssertEqual(a.integrity.verdict, .intact, "\(a.integrity.checks)")
        XCTAssertTrue(a.integrity.checks.contains { $0.name == "png-chunks" && $0.outcome == .passed })
        XCTAssertTrue(a.integrity.checks.contains { $0.name == "probe-sanity" && $0.outcome == .passed })
        XCTAssertFalse(a.integrity.checks.contains { $0.name == "decode" },
                       "structural tier must not have paid for a decode pass")
    }

    /// The swallow fix: a truncated JPEG used to be silently omitted; now it must arrive with a
    /// verdict and a diagnosis a production log can act on.
    func testCorruptFileYieldsDiagnosisInsteadOfVanishing() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let good = tmp.appendingPathComponent("whole.jpg")
        try writeJPEG(makeImage(96), to: good)
        let bad = tmp.appendingPathComponent("cut.jpg")
        let data = try Data(contentsOf: good)
        try data.prefix(data.count / 2).write(to: bad)

        var results: [Analysis] = []
        for await a in forge.analyze(.urls([good, bad])) { results.append(a) }
        XCTAssertEqual(results.count, 2, "the corrupt file must not vanish from the stream")

        let corrupt = try XCTUnwrap(results.first { $0.input == bad })
        XCTAssertEqual(corrupt.integrity.verdict, .corrupt)
        XCTAssertTrue(corrupt.integrity.detail?.contains("EOI") == true,
                      "\(String(describing: corrupt.integrity.detail))")
        XCTAssertTrue(corrupt.estimate.note.contains("not optimizable")
                   || corrupt.integrity.verdict == .corrupt)

        let intact = try XCTUnwrap(results.first { $0.input == good })
        XCTAssertEqual(intact.integrity.verdict, .intact)
    }

    func testUnknownBytesYieldUnverifiedNotAbsence() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let junk = tmp.appendingPathComponent("junk.bin")
        try Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 41 &+ 7) }).write(to: junk)

        var results: [Analysis] = []
        for await a in forge.analyze(.url(junk)) { results.append(a) }
        let a = try XCTUnwrap(results.first)
        XCTAssertEqual(a.kind, .unknown)
        XCTAssertEqual(a.integrity.verdict, .unverified)
    }

    func testDeepTierAddsDecodeCheck() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("clip.mp4")
        try makeClip(at: src, frames: 8)

        var results: [Analysis] = []
        for await a in forge.analyze(.url(src), Options(integrity: .deep)) { results.append(a) }
        let a = try XCTUnwrap(results.first)
        XCTAssertEqual(a.integrity.verdict, .intact, "\(a.integrity.checks)")
        let decode = try XCTUnwrap(a.integrity.checks.first { $0.name == "decode" })
        XCTAssertEqual(decode.outcome, .passed)
        XCTAssertTrue(decode.detail?.contains("samples") == true,
                      "deep must report how much it decoded: \(String(describing: decode.detail))")
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeImage(_ n: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let noise = ((x * 131 + y * 57) % 64) - 32
            let i = (y * n + x) * 4
            bytes[i] = UInt8(clamping: x * 3 + noise)
            bytes[i + 1] = UInt8(clamping: y * 3 + noise)
            bytes[i + 2] = UInt8(clamping: 128 + noise)
            bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ForgeError.renderFailed("png destination")
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { throw ForgeError.renderFailed("png finalize") }
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ForgeError.renderFailed("jpeg destination")
        }
        CGImageDestinationAddImage(dst, image, [
            kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw ForgeError.renderFailed("jpeg finalize") }
    }

    private func makeClip(at url: URL, frames: Int) throws {
        let w = 160, h = 120, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let o = y * rowBytes + x * 4
                    p[o] = UInt8((x * 255 / w + i * 9) % 256)
                    p[o + 1] = UInt8(y * 255 / h)
                    p[o + 2] = UInt8((x + y) * 255 / (w + h))
                    p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
    }
}
