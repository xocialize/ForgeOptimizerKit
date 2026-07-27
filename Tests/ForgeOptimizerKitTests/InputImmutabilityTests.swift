import XCTest
import AVFoundation
@testable import ForgeOptimizerKit

/// `OptimizeRequest` states a contract guarantee, verbatim:
///
/// > **`input` is strictly read-only (contract guarantee).** Forge READS the input and writes ONLY to
/// > `output` (+ its own temp dir) — it never writes, moves, renames, or mutates the input. A host with a
/// > write-once canonical original (Marquee's `Originals/`) can rely on it staying byte-identical.
///
/// Output paths are derived as `<dir>/<input-stem>.<ext>`, so a destination directory that happens to be
/// the input's own directory resolves onto the input whenever the extensions agree. These assert the
/// guarantee rather than the derivation, because the guarantee is what a host was told it could rely on.
final class InputImmutabilityTests: XCTestCase {

    private func makeClip(at url: URL, w: Int, h: Int, frames: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 20)
    }

    /// A destination directory equal to the input's own directory must not consume the input.
    func testOptimizingIntoTheInputsOwnDirectoryLeavesTheInputByteIdentical() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imm-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("clip.mp4")
        try makeClip(at: input, w: 64, h: 48, frames: 4)
        let original = try Data(contentsOf: input)

        let forge = ForgeOptimizer(enhancer: DoublingEnhancer(), flowProvider: ZeroFlowProvider())
        for await _ in try forge.optimize(.url(input), to: .directory(dir),
                                          Options(quality: .balanced, upscale: .x2)) {}

        let after = try Data(contentsOf: input)
        XCTAssertEqual(original, after,
                       "the contract says the input stays byte-identical; it was overwritten")
    }

    /// The derivation itself, asserted directly so the cause is legible when the guarantee test fails.
    func testResolvedOutputNeverEqualsTheInputPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imm2-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("clip.mp4")
        FileManager.default.createFile(atPath: input.path, contents: Data([0, 1, 2, 3]))

        let forge = ForgeOptimizer()
        let out = try forge.videoOutputURLForTesting(input: input, destination: .directory(dir))
        XCTAssertNotEqual(out.standardizedFileURL, input.standardizedFileURL,
                          "output resolved onto the input path")
    }
}

extension InputImmutabilityTests {

    /// An *explicitly named* output equal to the input must throw, not be quietly renamed. Forge chooses
    /// derived names, so it may adjust them; an explicit path is the host's instruction, and silently
    /// writing somewhere else would be its own dishonesty.
    func testExplicitFileURLEqualToInputThrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imm3-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("clip.mp4")
        try makeClip(at: input, w: 64, h: 48, frames: 4)

        let forge = ForgeOptimizer()
        XCTAssertThrowsError(try forge.videoOutputURLForTesting(input: input,
                                                                destination: .fileURL(input))) { error in
            guard case ForgeError.outputWouldOverwriteInput = error else {
                return XCTFail("expected outputWouldOverwriteInput, got \(error)")
            }
        }
    }

    /// A *different* explicit path is untouched — the guard must not over-trigger.
    func testExplicitFileURLElsewhereIsHonouredExactly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imm4-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("clip.mp4")
        FileManager.default.createFile(atPath: input.path, contents: Data([0, 1]))
        let wanted = dir.appendingPathComponent("somewhere-else.mp4")

        let out = try ForgeOptimizer().videoOutputURLForTesting(input: input, destination: .fileURL(wanted))
        XCTAssertEqual(out, wanted, "an explicit path that does not collide must be used verbatim")
    }

    /// The disambiguated name must stay a usable sibling, not a mangled path.
    func testDisambiguatedNameIsAReadableSibling() {
        let input = URL(fileURLWithPath: "/tmp/x/clip.mp4")
        let out = ForgeOptimizer.disambiguating(input, from: input)
        XCTAssertEqual(out.lastPathComponent, "clip.optimized.mp4")
        XCTAssertEqual(out.deletingLastPathComponent(), input.deletingLastPathComponent())
    }
}
