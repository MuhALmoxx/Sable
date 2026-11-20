import SwiftUI
import SubtitleKit

// OWNER: sync agent. Precise zoomed timeline for the Mark step: ±5 s around the playhead,
// a tick every 0.1 s, labelled whole seconds, the active track's lines (at their EFFECTIVE
// times), the user's mark and the loudness suggestion. Drag sideways to scrub (the ruler moves
// with the finger, like tape under a fixed playhead) with a haptic tick per 0.1 s.
struct SyncTimeline: View {
    let model: GuidedSyncModel
    let session: PlayerSession

    static let halfSpan: TimeInterval = SyncTimelineMetrics.halfSpan

    @State private var dragStartTime: TimeInterval?
    @State private var lastTick: Int?
    /// True while a finger is down. Unlike `onEnded`, this also resets when the system cancels
    /// the drag (sheet/scroll takes over, app backgrounded), so a scrub is always finished.
    @GestureState private var isTouching = false
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 104

    var body: some View {
        let center = model.displayTime
        let snapshot = TimelineSnapshot(
            center: center.isFinite ? center : 0,
            duration: session.duration,
            spans: visibleSpans(around: center),
            mark: model.markedTime,
            suggestion: model.suggestedOnset
        )
        GeometryReader { geo in
            Canvas { context, size in
                snapshot.draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geo.size.width))
        }
        .onChange(of: isTouching) { _, touching in
            if !touching { finishDrag() }
        }
        .frame(height: height)
        .background(Palette.surface)
        .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("Precise timeline, 5 seconds either side of the playhead")
        .accessibilityValue(SyncFormat.precise(center))
        .accessibilityHint("Swipe up or down to move 0.1 seconds. Drag sideways to scrub.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.stepPlayhead(by: 0.1)
            case .decrement: model.stepPlayhead(by: -0.1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(AX.Sync.timeline)
    }

    /// Effective intervals of the lines near the playhead.
    private func visibleSpans(around center: TimeInterval) -> [ClosedRange<TimeInterval>] {
        guard let cues = model.track?.document.cues, !cues.isEmpty else { return [] }
        let timing = session.timing
        let lower = center - Self.halfSpan - 1
        let upper = center + Self.halfSpan + 1
        var spans: [ClosedRange<TimeInterval>] = []
        for cue in SyncMath.candidateCues(cues, around: center, window: Self.halfSpan + 1, timing: timing) {
            let s = timing.effective(cue.start)
            let e = max(s, timing.effective(cue.end))
            guard e >= lower, s <= upper else { continue }
            spans.append(s...e)
        }
        return spans
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                if dragStartTime == nil {
                    // Ignore mostly-vertical drags so the sheet can still scroll.
                    guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                    dragStartTime = model.displayTime
                    lastTick = Int((model.displayTime * 10).rounded(.down))
                    model.beginScrub()
                }
                guard let start = dragStartTime else { return }
                let pointsPerSecond = max(1, width / CGFloat(2 * Self.halfSpan))
                let target = model.clampToMedia(start - Double(value.translation.width / pointsPerSecond))
                model.scrub(to: target)
                let tick = Int((target * 10).rounded(.down))
                if let last = lastTick, tick != last {
                    if tick / 10 != last / 10 { SyncHaptics.majorTick() } else { SyncHaptics.tick() }
                }
                lastTick = tick
            }
            .onEnded { _ in finishDrag() }
    }

    /// Ends the scrub once per gesture, whether it ended normally or was cancelled.
    private func finishDrag() {
        if dragStartTime != nil { model.endScrub() }
        dragStartTime = nil
        lastTick = nil
    }
}

/// Nonisolated constants shared by the view and its renderer.
enum SyncTimelineMetrics {
    /// Seconds shown either side of the playhead.
    static let halfSpan: TimeInterval = 5
}

/// Immutable drawing input, so the Canvas renderer captures plain values only.
private struct TimelineSnapshot {
    let center: TimeInterval
    let duration: TimeInterval
    let spans: [ClosedRange<TimeInterval>]
    let mark: TimeInterval?
    let suggestion: TimeInterval?

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        guard width > 0 else { return }
        let half = SyncTimelineMetrics.halfSpan
        let pps = width / CGFloat(2 * half)
        func x(_ t: TimeInterval) -> CGFloat { (width / 2 + CGFloat(t - center) * pps).rounded() }

        let labelTop: CGFloat = 4
        let tickTop: CGFloat = 20
        let bandTop = size.height * 0.52
        let bandHeight = max(12, size.height * 0.22)

        // Ticks: every 0.1 s, taller at 0.5 s, tallest + labelled at whole seconds.
        let first = Int(((center - half) * 10).rounded(.up))
        let last = Int(((center + half) * 10).rounded(.down))
        var minor = Path()
        var medium = Path()
        var major = Path()
        if first <= last {
            for k in first...last {
                let t = Double(k) / 10
                if t < 0 || (duration > 0 && t > duration + 0.05) { continue }
                let px = x(t)
                if k % 10 == 0 {
                    major.addRect(CGRect(x: px, y: tickTop, width: 1, height: 18))
                    let label = Text(SyncFormat.tickLabel(k / 10))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textSecondary)
                    context.draw(label, at: CGPoint(x: px, y: labelTop), anchor: .top)
                } else if k % 5 == 0 {
                    medium.addRect(CGRect(x: px, y: tickTop, width: 1, height: 11))
                } else {
                    minor.addRect(CGRect(x: px, y: tickTop, width: 1, height: 6))
                }
            }
        }
        context.fill(minor, with: .color(Palette.border))
        context.fill(medium, with: .color(Palette.borderStrong))
        context.fill(major, with: .color(Palette.textTertiary))

        // Outside the media.
        if center - half < 0 {
            let edge = x(0)
            context.fill(Path(CGRect(x: 0, y: 0, width: max(0, edge), height: size.height)),
                         with: .color(Palette.background.opacity(0.6)))
        }
        if duration > 0 && center + half > duration {
            let edge = x(duration)
            context.fill(Path(CGRect(x: edge, y: 0, width: max(0, width - edge), height: size.height)),
                         with: .color(Palette.background.opacity(0.6)))
        }

        // Subtitle lines (effective times): a band per line with a bright start edge.
        for span in spans {
            let x0 = max(-2, x(span.lowerBound))
            let x1 = min(width + 2, max(x0 + 2, x(span.upperBound)))
            let rect = CGRect(x: x0, y: bandTop, width: x1 - x0, height: bandHeight)
            context.fill(Path(rect), with: .color(Palette.surfaceHigh))
            context.stroke(Path(rect), with: .color(Palette.border), lineWidth: 1)
            context.fill(Path(CGRect(x: x0, y: bandTop, width: 2, height: bandHeight)),
                         with: .color(Palette.textSecondary))
        }

        // Loudness suggestion: dashed line.
        if let suggestion, abs(suggestion - center) <= half {
            var path = Path()
            let px = x(suggestion) + 0.5
            path.move(to: CGPoint(x: px, y: tickTop))
            path.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(path, with: .color(Palette.textSecondary),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        // The user's mark: solid line with a flag.
        if let mark, abs(mark - center) <= half {
            let px = x(mark)
            context.fill(Path(CGRect(x: px, y: tickTop, width: 1, height: size.height - tickTop)),
                         with: .color(Palette.textPrimary))
            context.fill(Path(CGRect(x: px, y: size.height - 12, width: 8, height: 6)),
                         with: .color(Palette.textPrimary))
        }

        // Playhead (the active element): accent line with a notch on top.
        let mid = (width / 2).rounded()
        context.fill(Path(CGRect(x: mid - 1, y: tickTop - 4, width: 2, height: size.height - tickTop + 4)),
                     with: .color(Palette.accent))
        context.fill(Path(CGRect(x: mid - 4, y: tickTop - 6, width: 8, height: 3)),
                     with: .color(Palette.accent))
    }
}
