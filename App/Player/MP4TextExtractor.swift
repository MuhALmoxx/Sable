import Foundation
import AVFoundation
import CoreMedia
import SubtitleKit

// OWNER: playback agent. Reads an MP4 text track (3GPP timed text "tx3g"/mov_text, or WebVTT
// "wvtt") with AVAssetReader and turns its samples into cues. Run off the main actor.

enum MP4TextExtractor {
    static func extract(url: URL, trackID: Int, format: SubtitleFormat, language: LanguageCode?, title: String?,
                        progress: (@Sendable (Double) -> Void)? = nil,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> SubtitleDocument {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTrack(withTrackID: CMPersistentTrackID(trackID)) else {
            throw PlayerError("The subtitle track is no longer in the video file.")
        }
        let totalDuration = (try? await asset.load(.duration))?.seconds.finiteOrZero ?? 0

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw PlayerError("The video's subtitle track can't be read: \(error.localizedDescription)")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PlayerError("This MP4 subtitle track can't be read by AVFoundation.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw PlayerError("The video's subtitle track can't be read: \(reader.error?.localizedDescription ?? "unknown error")")
        }

        var cues: [SubtitleCue] = []
        var sawPayload = false
        var lastReported = -1.0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw SubtitleError.cancelled
            }
            for sample in samples(in: sampleBuffer) {
                guard !sample.data.isEmpty else { continue }
                let texts: [String]
                switch format {
                case .webvtt:
                    texts = WebVTTSampleDecoder.cueTexts(in: sample.data)
                default:
                    texts = TX3GDecoder.decodeSample(sample.data).map { [$0] } ?? []
                }
                if sample.data.count > 2 { sawPayload = true }
                let end = sample.duration > 0 ? sample.start + sample.duration : sample.start + 2
                for text in texts {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    cues.append(SubtitleCue(id: "c\(cues.count)", index: cues.count,
                                            start: sample.start, end: end, text: trimmed))
                }
                if let progress, totalDuration > 0 {
                    let fraction = min(1, max(0, end / totalDuration))
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
        }
        if reader.status == .failed {
            throw PlayerError("Reading the subtitle track failed: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard !cues.isEmpty else {
            if format == .webvtt && sawPayload {
                throw PlayerError("This WebVTT-in-MP4 track uses a layout Sable doesn't support yet.")
            }
            throw SubtitleError.empty
        }
        progress?(1)
        return SubtitleDocument(format: format, cues: cues, language: language, title: title).normalized()
    }

    struct Sample {
        var start: TimeInterval
        var duration: TimeInterval
        var data: Data
    }

    /// Splits a sample buffer into its samples (text tracks usually carry one per buffer).
    static func samples(in buffer: CMSampleBuffer) -> [Sample] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return [] }
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return [] }

        let count = CMSampleBufferGetNumSamples(buffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds.finiteOrZero
        let bufferDuration = CMSampleBufferGetDuration(buffer).seconds.finiteOrZero
        guard count > 1 else {
            return [Sample(start: pts, duration: bufferDuration, data: bytes)]
        }

        var sizeCount: CMItemCount = 0
        CMSampleBufferGetSampleSizeArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount)
        var sizes = [Int](repeating: 0, count: max(sizeCount, 0))
        if sizeCount > 0 {
            CMSampleBufferGetSampleSizeArray(buffer, entryCount: sizeCount, arrayToFill: &sizes, entriesNeededOut: nil)
        }
        var timingCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(timingCount, 0))
        if timingCount > 0 {
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: nil)
        }
        guard sizes.count == count || sizes.count == 1 else {
            return [Sample(start: pts, duration: bufferDuration, data: bytes)]
        }

        var result: [Sample] = []
        var offset = 0
        var runningStart = pts
        for index in 0..<count {
            let size = sizes.count == 1 ? sizes[0] : sizes[index]
            guard size >= 0, offset + size <= bytes.count else { break }
            let timing = timings.isEmpty ? nil : timings[min(index, timings.count - 1)]
            var start = runningStart
            if let timing, timings.count == count {
                start = timing.presentationTimeStamp.seconds.finiteOrZero
            }
            let duration = timing?.duration.seconds.finiteOrZero ?? (bufferDuration / Double(count))
            result.append(Sample(start: start, duration: duration, data: bytes.subdata(in: offset..<(offset + size))))
            offset += size
            runningStart = start + duration
        }
        return result
    }
}

/// WebVTT-in-ISOBMFF samples (ISO/IEC 14496-30): a sample is a list of boxes; each 'vttc' box
/// holds a cue whose text is in a 'payl' child box. 'vtte' boxes are empty gaps.
enum WebVTTSampleDecoder {
    static func cueTexts(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var texts: [String] = []
        for box in boxes(in: bytes[...]) where box.type == "vttc" {
            for child in boxes(in: box.payload) where child.type == "payl" {
                if let raw = String(bytes: child.payload, encoding: .utf8) {
                    texts.append(cleaned(raw))
                }
            }
        }
        return texts
    }

    private struct Box {
        var type: String
        var payload: ArraySlice<UInt8>
    }

    private static func boxes(in bytes: ArraySlice<UInt8>) -> [Box] {
        var result: [Box] = []
        var index = bytes.startIndex
        while index + 8 <= bytes.endIndex {
            let size = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let type = String(bytes: bytes[(index + 4)..<(index + 8)], encoding: .ascii) ?? ""
            guard size >= 8, index + size <= bytes.endIndex else { break }
            result.append(Box(type: type, payload: bytes[(index + 8)..<(index + size)]))
            index += size
        }
        return result
    }

    /// Drops WebVTT spans (<v Name>, <c.class>, <lang>, timestamps) but keeps <i>/<b>/<u>, and
    /// decodes the common character references.
    static func cleaned(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<(?!/?[ibu]>)[^>]*>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": "\u{00A0}", "&lrm;": "\u{200E}", "&rlm;": "\u{200F}"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }
}
