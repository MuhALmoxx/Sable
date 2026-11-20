import Foundation

// OWNER: sync agent. Pure signal maths behind the optional "suggested onset" in guided sync.
// This is a loudness heuristic, NOT speech recognition: it finds places where the audio gets
// clearly louder after a stretch of relative quiet. The user always confirms or corrects it.
// Foundation-only and free of actor isolation so it can run on any thread.

enum OnsetAnalysis {
    /// Analysis frame length (10 ms).
    static let frameDuration: TimeInterval = 0.010

    struct Parameters: Sendable {
        /// Frames of relative quiet required before an onset (150 ms).
        var minQuietFrames = 15
        /// Of the frames starting at the threshold crossing, how many must stay loud …
        var minLoudFrames = 5
        /// … within this many frames (rejects clicks and single transients).
        var loudnessWindowFrames = 8
        /// Minimum distance between the quiet floor and the loud level for any onset to count.
        var minDynamicRangeDB: Double = 12
        /// Loud threshold sits at least this far above the floor …
        var minRiseDB: Double = 10
        /// … or at this fraction of the floor-to-peak range, whichever is higher.
        var loudFraction: Double = 0.5
        /// Quiet threshold sits this fraction of the floor-to-loud distance above the floor.
        var quietFraction: Double = 0.5
        /// A rise must climb from quiet to loud within this many frames (100 ms).
        var maxRiseFrames = 10
    }

    /// RMS energy per 10 ms frame in dBFS (silence is clamped at −120 dB).
    static func frameEnergies(_ samples: [Float], sampleRate: Double) -> [Double] {
        let n = max(1, Int((sampleRate * frameDuration).rounded()))
        guard samples.count >= n else { return [] }
        var energies: [Double] = []
        energies.reserveCapacity(samples.count / n)
        var start = 0
        while start + n <= samples.count {
            var sum: Double = 0
            for i in start..<(start + n) {
                let v = Double(samples[i])
                sum += v * v
            }
            let rms = (sum / Double(n)).squareRoot()
            energies.append(20 * log10(max(rms, 1e-6)))
            start += n
        }
        return energies
    }

    /// Times (seconds, in the same clock as `startTime`) where a strong onset begins:
    /// energy rises above an adaptive "loud" threshold after at least 150 ms below an adaptive
    /// "quiet" threshold. The reported time is the first frame that left the quiet level.
    static func onsets(energies: [Double], startTime: TimeInterval,
                       parameters p: Parameters = Parameters()) -> [TimeInterval] {
        guard energies.count >= p.minQuietFrames + p.loudnessWindowFrames + 2 else { return [] }
        let sorted = energies.sorted()
        let floor = percentile(sorted, 0.15)
        let peak = percentile(sorted, 0.95)
        let range = peak - floor
        guard range >= p.minDynamicRangeDB else { return [] }
        let loud = floor + max(p.minRiseDB, p.loudFraction * range)
        let quiet = floor + p.quietFraction * (loud - floor)

        var result: [TimeInterval] = []
        var i = 1
        while i < energies.count {
            guard energies[i] >= loud, energies[i - 1] < loud else { i += 1; continue }
            // Walk back to the first frame that left the quiet level.
            var riseStart = i
            while riseStart > 0 && energies[riseStart - 1] >= quiet && i - riseStart < p.maxRiseFrames {
                riseStart -= 1
            }
            let risesFromQuiet = riseStart > 0 && energies[riseStart - 1] < quiet
            // Require the preceding stretch to be quiet for long enough.
            var quietRun = 0
            var j = riseStart - 1
            while j >= 0 && energies[j] < quiet && quietRun < p.minQuietFrames {
                quietRun += 1
                j -= 1
            }
            // Require the sound to stay loud (not a click).
            let windowEnd = min(energies.count, i + p.loudnessWindowFrames)
            let loudCount = energies[i..<windowEnd].filter { $0 >= loud }.count
            if risesFromQuiet && quietRun >= p.minQuietFrames && loudCount >= p.minLoudFrames {
                result.append(startTime + Double(riseStart) * frameDuration)
                // Skip the rest of this loud stretch.
                var k = i
                while k < energies.count && energies[k] >= quiet { k += 1 }
                i = max(k, i + 1)
            } else {
                i += 1
            }
        }
        return result
    }

    /// Convenience: samples -> onsets.
    static func onsets(samples: [Float], sampleRate: Double, startTime: TimeInterval,
                       parameters: Parameters = Parameters()) -> [TimeInterval] {
        onsets(energies: frameEnergies(samples, sampleRate: sampleRate), startTime: startTime, parameters: parameters)
    }

    /// The onset that best explains a user's tap at `mark`. People usually tap a little LATE,
    /// so onsets before the mark are preferred: the search covers [mark − 1.2 s, mark + 0.8 s]
    /// and later onsets count 1.5× their distance.
    static func bestOnset(_ onsets: [TimeInterval], near mark: TimeInterval) -> TimeInterval? {
        var best: (time: TimeInterval, cost: Double)?
        for onset in onsets {
            let delta = onset - mark
            guard delta >= -1.2, delta <= 0.8 else { continue }
            let cost = delta < 0 ? -delta : delta * 1.5
            if best == nil || cost < best!.cost { best = (onset, cost) }
        }
        return best?.time
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded())
        return sorted[index]
    }
}
