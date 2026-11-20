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

/// "More": what is playing and with which engine, plus switching engines.
struct PlaybackInfoSheet: View {
    let session: PlayerSession
    var onClose: () -> Void

    var body: some View {
        PixelSheet(title: "Playback", subtitle: session.item.title, onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionLabel("Now playing")
                    infoRow("Engine", session.engineKind?.displayName ?? "—")
                    infoRow("Container", containerLabel)
                    infoRow("Picture", pictureLabel)
                    infoRow("Duration", TimecodeFormatter.precise(session.duration))
                    infoRow("Picture in Picture", session.isPictureInPictureSupported ? "Available" : "Not available")
                    Text(engineNote)
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.xxs)
                    if session.engineKind == .avFoundation {
                        Button("Reopen with VLC") {
                            onClose()
                            Task { await session.retryWithVLC() }
                        }
                        .buttonStyle(PixelButtonStyle(kind: .secondary))
                        .accessibilityIdentifier(AX.Player.tryVLC)
                    } else if session.engineKind == .vlc && session.isPlayableByAVFoundation {
                        Button("Reopen with AVFoundation") {
                            onClose()
                            Task { await session.reopenWithAVFoundation() }
                        }
                        .buttonStyle(PixelButtonStyle(kind: .secondary))
                    }
                }
                .padding(Spacing.md)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Spacing.sm)
            Text(value).font(Typo.mono).foregroundStyle(Palette.textPrimary).multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    private var containerLabel: String {
        switch session.container {
        case .matroska: return session.item.fileExtension == "webm" ? "WebM" : "Matroska"
        case .mp4: return session.item.fileExtension == "mov" ? "QuickTime" : "MP4"
        case .other: return session.item.fileExtension.uppercased()
        case nil: return "—"
        }
    }

    private var pictureLabel: String {
        guard let size = session.videoSize, size.width > 0, size.height > 0 else { return "—" }
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    private var engineNote: String {
        switch session.engineKind {
        case .avFoundation:
            return "AVFoundation decodes in hardware and supports Picture in Picture. Sable draws the subtitles itself on both engines."
        case .vlc:
            return "VLC plays containers and codecs AVFoundation can't (MKV, WebM, AVI…). VLCKit has no Picture in Picture, so playback pauses when Sable goes to the background."
        case nil:
            return ""
        }
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
