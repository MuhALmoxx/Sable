import Foundation
import AVFoundation
import CoreMedia

// OWNER: sync agent. Reads a few seconds of audio around the user's mark and proposes the
// nearest strong onset ("Suggested onset …"). Only for media AVFoundation can read (the
// AVFoundation engine); MKV/VLC media is not analysed. Never runs on the main actor.

enum SpeechOnsetError: LocalizedError, Equatable {
    case noAudioTrack
    case unreadable(String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "This video has no audio track Sable can read."
        case let .unreadable(reason): return "The audio couldn't be read (\(reason))."
        case .noAudio: return "No audio was found around your mark."
        }
    }
}

/// Decoded mono PCM and the media time of its first sample.
struct DecodedPCM: Sendable {
    let samples: [Float]
    let startTime: TimeInterval
}

struct OnsetSuggestionResult: Equatable, Sendable {
    /// Media time the analysis window was centred on.
    let center: TimeInterval
    /// Every strong onset found in the window, in media time.
    let onsets: [TimeInterval]
}

enum SpeechOnsetDetector {
    /// Mono 16 kHz is plenty for speech energy and keeps the work tiny (≈ 100 k samples).
    static let sampleRate: Double = 16_000

    /// Analyses [center − radius, center + radius] (clamped to the media) and returns the
    /// onsets found there. Runs the decoding on a background queue; cancellable.
    static func detectOnsets(in url: URL, around center: TimeInterval, radius: TimeInterval = 3,
                             mediaDuration: TimeInterval) async throws -> OnsetSuggestionResult {
        let start = max(0, center - radius)
        var end = center + radius
        if mediaDuration > 0 { end = min(end, mediaDuration) }
        guard end - start > 0.3 else { throw SpeechOnsetError.noAudio }

        let pcm = try await readMonoPCM(url: url, start: start, duration: end - start)
        try Task.checkCancellation()
        guard !pcm.samples.isEmpty else { throw SpeechOnsetError.noAudio }
        let rate = sampleRate
        let onsets = await Task.detached(priority: .userInitiated) { () async -> [TimeInterval] in
            OnsetAnalysis.onsets(samples: pcm.samples, sampleRate: rate, startTime: pcm.startTime)
        }.value
        return OnsetSuggestionResult(center: center, onsets: onsets)
    }

    /// Decodes the first enabled audio track to mono Float32 PCM at 16 kHz for the given range.
    /// `startTime` is the media time of the first returned sample.
    static func readMonoPCM(url: URL, start: TimeInterval, duration: TimeInterval) async throws -> DecodedPCM {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw SpeechOnsetError.unreadable(error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw SpeechOnsetError.noAudioTrack }
        // Prefer the track AVFoundation plays by default (the first enabled one).
        var chosen = tracks[0]
        for track in tracks {
            if (try? await track.load(.isEnabled)) == true {
                chosen = track
                break
            }
        }
        try Task.checkCancellation()

        let track = chosen
        let task = Task.detached(priority: .userInitiated) { () async throws -> DecodedPCM in
            try SpeechOnsetDetector.decode(asset: asset, track: track, start: start, duration: duration)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Synchronous decode loop (runs inside a detached task).
    private static func decode(asset: AVAsset, track: AVAssetTrack, start: TimeInterval,
                               duration: TimeInterval) throws -> DecodedPCM {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SpeechOnsetError.unreadable(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpeechOnsetError.unreadable("unsupported audio format") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        guard reader.startReading() else {
            throw SpeechOnsetError.unreadable(reader.error?.localizedDescription ?? "reader did not start")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * sampleRate) + 4096)
        var firstTime: TimeInterval?
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { throw CancellationError() }
            if firstTime == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                if pts.isValid && pts.isNumeric { firstTime = pts.seconds }
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == noErr else { continue }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed {
            throw SpeechOnsetError.unreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
        return DecodedPCM(samples: samples, startTime: firstTime ?? start)
    }
}
