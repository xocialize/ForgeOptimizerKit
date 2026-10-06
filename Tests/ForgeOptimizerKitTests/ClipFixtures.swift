import XCTest
import AVFoundation
import CoreVideo
@testable import ForgeOptimizerKit

/// Clip fixtures the video tests share: an H.264 gradient clip, optionally with a soundtrack — the case both upscale
/// routes must carry through (the upscalers write video only; the Kit muxes the source audio back).
extension XCTestCase {
    /// An H.264 gradient clip at 30 fps, optionally with a mono 440 Hz AAC track spanning it (LPCM in a `.mov`
    /// under `pcmMov`).
    func writeClip(to url: URL, w: Int, h: Int, frames: Int, audio: Bool, pcmMov: Bool = false) throws {
        let fps = 30, rate = 44_100
        let writer = try AVAssetWriter(outputURL: url, fileType: pcmMov ? .mov : .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(video)
        var sound: AVAssetWriterInput?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmMov
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                   AVLinearPCMIsNonInterleaved: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
                   AVEncoderBitRateKey: 64_000])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            sound = a
        }
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let samplesPerFrame = rate / fps
        for i in 0..<frames {
            while !video.isReadyForMoreMediaData { usleep(500) }
            adaptor.append(try gradientFrame(w, h, i), withPresentationTime: CMTime(value: CMTimeValue(i),
                                                                                   timescale: CMTimeScale(fps)))
            if let sound {
                while !sound.isReadyForMoreMediaData { usleep(500) }
                sound.append(try toneBuffer(start: i * samplesPerFrame, count: samplesPerFrame, rate: rate))
            }
        }
        video.markAsFinished()
        sound?.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        guard writer.status == .completed else {
            throw ForgeError.renderFailed("fixture writer: \(String(describing: writer.error))")
        }
    }

    private func gradientFrame(_ w: Int, _ h: Int, _ i: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        let buf = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buf)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let o = y * rowBytes + x * 4
                p[o] = UInt8((x * 255 / w + i * 6) % 256)
                p[o + 1] = UInt8(y * 255 / h)
                p[o + 2] = UInt8((x + y) * 255 / (w + h))
                p[o + 3] = 255
            } }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func toneBuffer(start: Int, count: Int, rate: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        var pcm = (0..<count).map { Int16(sin(Double(start + $0) * 2 * .pi * 440 / Double(rate)) * 8000) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        let data = try XCTUnwrap(block)
        CMBlockBufferReplaceDataBytes(with: &pcm, blockBuffer: data, offsetIntoDestination: 0, dataLength: count * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: try XCTUnwrap(format), sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
