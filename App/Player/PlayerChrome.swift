import SwiftUI
import UIKit
import SubtitleKit
import LibraryKit

// OWNER: playback agent. Building blocks of the player screen.

// MARK: - Engine surface

/// Hosts the engine's rendering view (AVPlayerLayer host or VLC drawable) full-bleed.
struct EngineSurface: UIViewRepresentable {
    let engineView: UIView?

    func makeUIView(context: Context) -> EngineHostView { EngineHostView() }

    func updateUIView(_ uiView: EngineHostView, context: Context) {
        uiView.host(engineView)
    }
}

final class EngineHostView: UIView {
    private var hosted: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func host(_ view: UIView?) {
        guard view !== hosted else { return }
        hosted?.removeFromSuperview()
        hosted = view
        if let view {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}

// MARK: - Spinner

/// Eight amber cells chasing around a 3×3 ring.
struct PixelSpinner: View {
    var size: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ring: [(Int, Int)] = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { context in
            let step = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.09) % 8
            Canvas { canvas, canvasSize in
                let cell = floor(min(canvasSize.width, canvasSize.height) / 3)
                let gap = max(1, (cell * 0.18).rounded())
                for (index, position) in Self.ring.enumerated() {
                    let age = (step - index + 8) % 8
                    let opacity: Double = age == 0 ? 1 : age == 1 ? 0.6 : age == 2 ? 0.35 : 0.15
                    let rect = CGRect(x: CGFloat(position.0) * cell + gap / 2, y: CGFloat(position.1) * cell + gap / 2,
                                      width: cell - gap, height: cell - gap)
                    canvas.fill(Path(rect), with: .color(Palette.accent.opacity(opacity)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Scrubber and time labels

/// Pixel scrubber: drag to scrub with a precise timecode preview, tap to seek.
struct PixelScrubber: View {
    let session: PlayerSession
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let duration = session.duration
            let playhead = session.scrubTime ?? session.currentTime
            let fraction = dragFraction ?? (duration > 0 ? min(1, max(0, playhead / duration)) : 0)
            let knob: CGFloat = 12
            let x = (width * fraction).rounded()

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Palette.surfaceHigh)
                    .frame(height: 4)
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: max(0, x), height: 4)
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: knob, height: knob)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                    .offset(x: min(max(0, x - knob / 2), width - knob))
                if let dragFraction {
                    let label = TimecodeFormatter.precise(dragFraction * duration)
                    Text(label)
                        .font(Typo.mono)
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Rectangle().fill(Color.black.opacity(0.85)))
                        .overlay(Rectangle().stroke(Palette.accent, lineWidth: 1))
                        .fixedSize()
                        .offset(x: min(max(0, x - 50), max(0, width - 100)), y: -30)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if dragFraction == nil { onScrubbingChanged(true) }
                        let newFraction = min(1, max(0, value.location.x / width))
                        dragFraction = newFraction
                        session.scrub(to: newFraction * duration)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let newFraction = min(1, max(0, value.location.x / width))
                        dragFraction = nil
                        onScrubbingChanged(false)
                        Task { await session.endScrub(at: newFraction * duration) }
                    }
            )
        }
        .frame(height: Spacing.touch)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(TimecodeFormatter.playerTime(session.currentTime)) of \(TimecodeFormatter.playerTime(session.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: session.skip(by: 10)
            case .decrement: session.skip(by: -10)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(AX.Player.scrubber)
    }
}

struct CurrentTimeLabel: View {
    let session: PlayerSession

    var body: some View {
        let text = TimecodeFormatter.playerTime(session.scrubTime ?? session.currentTime)
        Text(text)
            .font(Typo.mono)
            .monospacedDigit()
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(text)
            .accessibilityIdentifier(AX.Player.currentTime)
    }
}

struct DurationLabel: View {
    let session: PlayerSession

    var body: some View {
        let text = TimecodeFormatter.playerTime(session.duration)
        Text(text)
            .font(Typo.mono)
            .monospacedDigit()
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Duration \(text)")
            .accessibilityIdentifier(AX.Player.duration)
    }
}

// MARK: - Device: brightness and orientation

@MainActor
enum DeviceControls {
    static var windowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    static var brightness: CGFloat {
        get { windowScene?.screen.brightness ?? 0.5 }
        set { windowScene?.screen.brightness = min(1, max(0, newValue)) }
    }

    static var isLandscape: Bool {
        windowScene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
    }

    /// Asks the scene to rotate to landscape (from portrait) or back to portrait.
    static func toggleOrientation() {
        guard let scene = windowScene else { return }
        let toLandscape = !scene.effectiveGeometry.interfaceOrientation.isLandscape
        let mask: UIInterfaceOrientationMask = toLandscape ? .landscapeRight : .portrait
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            playbackLog.error("Rotation request failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Small sheets

struct SpeedSheet: View {
    let session: PlayerSession
    var onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: Spacing.xs)]

    var body: some View {
        PixelSheet(title: "Speed", subtitle: Self.label(session.rate), onClose: onClose) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Spacing.xs) {
                    ForEach(AppSettings.rateOptions, id: \.self) { rate in
                        let label = Self.label(rate)
                        OptionChip(label: label, isSelected: abs(session.rate - rate) < 0.001,
                                   identifier: AX.Player.speedOption(label)) {
                            session.setRate(rate)
                        }
                    }
                }
                .padding(Spacing.md)
            }
        }
    }

    static func label(_ rate: Float) -> String {
        let text = String(format: "%.2f", rate)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        return text + "×"
    }
}

struct AspectSheet: View {
    let session: PlayerSession
    var onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: Spacing.xs)]

    var body: some View {
        PixelSheet(title: "Aspect", subtitle: session.aspectMode.label, onClose: onClose) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Spacing.xs) {
                    ForEach(AspectMode.allCases, id: \.self) { mode in
                        OptionChip(label: mode.label, isSelected: session.aspectMode == mode,
                                   identifier: AX.Player.aspectOption(mode.rawValue)) {
                            session.setAspectMode(mode)
                        }
                    }
                }
                .padding(Spacing.md)
                Text("Pinch the video to switch between Fit and Fill.")
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Spacing.md)
            }
        }
    }
}
