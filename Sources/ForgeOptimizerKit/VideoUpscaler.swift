import AVFoundation
import Foundation

/// The **clip-level video upscale seam** — the whole-clip counterpart of `ImageEnhancer`'s per-frame
/// upscale, for `UpscaleTier.liveAction`.
///
/// Some video super-resolution models handle time themselves and want the clip, not frames: FlashVSR
/// streams the source through a causal DiT, 8 frames at a time, each chunk conditioned on the ones
/// before it. Behind the per-frame `ImageEnhancer` + SEA-RAFT path (V4b) it would lose exactly what
/// makes it a video model. The net-clean Kit names the contract; ForgeCore's engine implementation
/// runs FlashVSR (`EngineVideoUpscaler`), keeping the Kit MLX-free.
///
/// The Kit asks `availability` before any work and fails the item on a refusal with the upscaler's
/// reason — it never falls back to the per-frame tiers. It then muxes the SOURCE's audio back in
/// (the upscaler returns video only) and delivers: the upscaled clip itself under `optimize`, or the
/// web target-quality H.264 encode of it under `webOptimize`.
public protocol VideoUpscaler: Sendable {
    /// Whether `tier` can upscale a `width`×`height` clip by `factor` here, and if not, why.
    ///
    /// Unlike a still tier, the answer depends on the clip: a streaming video model's activation
    /// memory follows the OUTPUT frame size, so the same tier can fit a 480p source at ×4 and refuse
    /// a 1080p one. A UI asks with the selected clip's size to show the choice as unavailable with
    /// its reason.
    func availability(of tier: UpscaleTier, width: Int, height: Int,
                      factor: UpscaleFactor) async -> UpscaleTierAvailability

    /// Upscale the video track of `input` by `factor` and write it to `output` — video only; the Kit
    /// muxes the source's audio itself. `progress` reports output frames written against the clip's
    /// frame count, as the model emits them. Cancellation of the calling task must stop the run.
    ///
    /// Returns what actually ran, which is what the receipt names (never the request).
    func upscale(_ input: URL, factor: UpscaleFactor, tier: UpscaleTier, output: URL,
                 progress: @escaping @Sendable (_ framesDone: Int, _ frameCount: Int) -> Void)
        async throws -> VideoUpscaleReport
}

/// What one clip upscale actually ran, as the upscaler observed it.
public struct VideoUpscaleReport: Sendable, Equatable {
    /// The tier whose backer ran; nil when the upscaler cannot say.
    public var tier: UpscaleTier?
    /// That backer's model name ("FlashVSR"); nil likewise.
    public var model: String?

    public init(tier: UpscaleTier? = nil, model: String? = nil) {
        self.tier = tier
        self.model = model
    }
}

public extension UpscaleTier {
    /// Why a still cannot take `.liveAction` — the one wording the Kit's refusal and the default
    /// `ImageEnhancer.availability(of:)` share.
    static let liveActionStillReason =
        "live action is a whole-clip video tier — a still takes Fast, Best or Generative"

    /// Why a clip cannot take a generative stills tier (`isStillOnly`).
    static let generativeClipReason =
        "generative upscaling is stills only (frame-by-frame generation has no temporal model) — a clip takes Fast, Best or Live action"
}

extension ForgeOptimizer {

    /// Put `source`'s first audio track beside `video`'s video track in a new mp4 at `output`.
    ///
    /// Both tracks pass through untouched where the mp4 accepts them; audio it cannot carry as-is
    /// (LPCM from a `.mov`, say) is encoded to AAC-LC rather than dropped. Returns false, writing
    /// nothing, when the source has no audio. Throws when a mux was due and failed: a deliverable
    /// that silently lost its soundtrack is worse than a failed item.
    static func muxingSourceAudio(video: URL, audioFrom source: URL, to output: URL) async throws -> Bool {
        let sourceAsset = AVURLAsset(url: source)
        guard let atrack = try await sourceAsset.loadTracks(withMediaType: .audio).first else { return false }
        let videoAsset = AVURLAsset(url: video)
        guard let vtrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw ForgeError.renderFailed("the upscaled clip has no video track")
        }
        let videoFormat = try await vtrack.load(.formatDescriptions).first
        let audioFormat = try await atrack.load(.formatDescriptions).first
        let transform = try await vtrack.load(.preferredTransform)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw ForgeError.renderFailed("the mp4 cannot carry the upscaled video") }
        writer.add(videoIn)

        // Passthrough unless the mp4 refuses the format — LPCM it always refuses, so that never gets asked.
        let subtype = audioFormat.map { CMFormatDescriptionGetMediaSubType($0) }
        var audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        var audioOut = AVAssetReaderTrackOutput(track: atrack, outputSettings: nil)
        if subtype == kAudioFormatLinearPCM || !writer.canAdd(audioIn) {
            let asbd = audioFormat.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let channels = min(max(Int(asbd?.mChannelsPerFrame ?? 2), 1), 2)
            let rate = asbd.map { $0.mSampleRate > 0 ? $0.mSampleRate : 48_000 } ?? 48_000
            audioOut = AVAssetReaderTrackOutput(track: atrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate])
            audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
                AVEncoderBitRateKey: 96_000 * channels])
            guard writer.canAdd(audioIn) else { throw ForgeError.renderFailed("the mp4 cannot carry the source audio") }
        }
        audioIn.expectsMediaDataInRealTime = false
        writer.add(audioIn)

        let videoOut = AVAssetReaderTrackOutput(track: vtrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        let videoReader = try AVAssetReader(asset: videoAsset)
        videoReader.add(videoOut)
        let audioReader = try AVAssetReader(asset: sourceAsset)
        // Audio ends where the picture does — a soundtrack running past the last frame is not the clip.
        audioReader.timeRange = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
        audioReader.add(audioOut)

        guard writer.startWriting(), videoReader.startReading(), audioReader.startReading() else {
            throw ForgeError.renderFailed("audio mux could not start: "
                + ((writer.error ?? videoReader.error ?? audioReader.error).map { "\($0)" } ?? "unknown"))
        }
        writer.startSession(atSourceTime: .zero)

        // Each input drains on its own queue. Pumping one inline would stall it the moment the writer
        // wants the other track's samples to interleave — media-bridge's AB-A-0055 deadlock.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (input, output, label) in [(audioIn, audioOut, "audio"), (videoIn, videoOut, "video")] {
                group.enter()
                let finished = MuxOnce()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "forge.mux.\(label)")) {
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                            finished.run { input.markAsFinished(); group.leave() }
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
        await writer.finishWriting()
        guard writer.status == .completed, videoReader.status != .failed, audioReader.status != .failed else {
            try? FileManager.default.removeItem(at: output)
            throw ForgeError.renderFailed("audio mux failed: "
                + ((writer.error ?? videoReader.error ?? audioReader.error).map { "\($0)" }
                   ?? "status \(writer.status.rawValue)"))
        }
        return true
    }

    /// The codec of a file's first video track, in receipt words ("HEVC", "H.264"); nil when unreadable.
    /// Measured rather than assumed: the deliverable is whatever the upscaler wrote.
    static func videoCodecLabel(_ url: URL) async -> String? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return nil }
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case let code:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Runs its body once however many times it is asked — a mux pump's completion can be reached from
/// both the end-of-samples branch and a failed append.
private final class MuxOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
