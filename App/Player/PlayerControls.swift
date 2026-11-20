import SwiftUI
import SubtitleKit
import LibraryKit

// OWNER: playback agent. Controls drawn over the video and the portrait tool panel.

/// Top bar, centre transport and bottom scrubber over the video (auto-hidden while playing).
struct ControlsOverlay: View {
    let session: PlayerSession
    let landscape: Bool
    let onClose: () -> Void
    let onTool: (PlayerSheet) -> Void
    let onLock: () -> Void
    let onInteraction: () -> Void
    let onScrubbingChanged: (Bool) -> Void

    @Environment(AppServices.self) private var services

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .background(Rectangle().fill(Palette.scrim).ignoresSafeArea(edges: landscape ? [.top, .horizontal] : []))
                Spacer(minLength: 0)
                bottomBar
                    .background(Rectangle().fill(Palette.scrim).ignoresSafeArea(edges: landscape ? [.bottom, .horizontal] : []))
            }
            centerControls
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: Spacing.xxs) {
            PixelIconButton(.close, label: "Close player", action: onClose)
                .accessibilityIdentifier(AX.Player.close)
            if landscape {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.item.title)
                        .font(Typo.headline)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .accessibilityIdentifier(AX.Player.title)
                    if let active = session.activeSubtitle {
                        Text(active.descriptor.title.uppercased())
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: Spacing.xs)
            if let kind = session.engineKind {
                PixelTag(kind == .vlc ? "VLC" : "AVF")
                    .accessibilityLabel("Engine: \(kind.displayName)")
                    .accessibilityIdentifier(AX.Player.engineTag)
            }
            if session.isPictureInPictureSupported {
                PixelIconButton(.pip,
                                label: session.isPictureInPictureActive ? "Stop Picture in Picture" : "Start Picture in Picture",
                                isActive: session.isPictureInPictureActive) {
                    session.togglePictureInPicture()
                    onInteraction()
                }
                .accessibilityIdentifier(AX.Player.pipButton)
            }
            PixelIconButton(.rotate, label: landscape ? "Rotate to portrait" : "Rotate to landscape") {
                DeviceControls.toggleOrientation()
                onInteraction()
            }
            .accessibilityIdentifier(AX.Player.rotate)
            PixelIconButton(.lock, label: "Lock controls", action: onLock)
                .accessibilityIdentifier(AX.Player.lock)
        }
        .padding(.horizontal, Spacing.xs)
    }

    // MARK: Centre

    private var step: Double { services.settings.doubleTapSeekSeconds }

    private var centerControls: some View {
        HStack(spacing: landscape ? Spacing.xxl : Spacing.lg) {
            skipButton(forward: false)
            playPauseButton
            skipButton(forward: true)
        }
    }

    private var playPauseButton: some View {
        let playing = session.isPlaying
        let label = playing ? "Pause" : (session.status == .ended ? "Play again" : "Play")
        return Button {
            session.togglePlayPause()
            onInteraction()
        } label: {
            PixelIcon(playing ? .pause : .play, size: landscape ? 32 : 26, color: Palette.accent)
                .frame(width: landscape ? 72 : 60, height: landscape ? 72 : 60)
                .background(Rectangle().fill(Palette.scrim))
                .overlay(Rectangle().stroke(Palette.accent.opacity(0.7), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(AX.Player.playPause)
    }

    private func skipButton(forward: Bool) -> some View {
        let seconds = Int(step.rounded())
        return Button {
            session.skip(by: forward ? step : -step)
            onInteraction()
        } label: {
            VStack(spacing: 2) {
                PixelIcon(forward ? .skipForward : .skipBack, size: landscape ? 26 : 22, color: Palette.textPrimary)
                Text("\(seconds)")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(width: 56, height: 56)
            .background(Rectangle().fill(Palette.scrim))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "Forward \(seconds) seconds" : "Back \(seconds) seconds")
        .accessibilityIdentifier(forward ? AX.Player.skipForward : AX.Player.skipBack)
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                CurrentTimeLabel(session: session)
                PixelScrubber(session: session, onScrubbingChanged: onScrubbingChanged)
                DurationLabel(session: session)
            }
            .padding(.horizontal, Spacing.sm)
            if landscape {
                ToolStrip(session: session, compact: true, onTool: { tool in
                    onTool(tool)
                })
                .padding(.horizontal, Spacing.xs)
                .padding(.bottom, Spacing.xxs)
            }
        }
    }
}

// MARK: - Tools

enum PlayerTool: CaseIterable, Identifiable {
    case subtitles, audio, speed, aspect, translate, timing, sync

    var id: Self { self }

    var sheet: PlayerSheet {
        switch self {
        case .subtitles: return .tracks
        case .audio: return .audio
        case .speed: return .speed
        case .aspect: return .aspect
        case .translate: return .translate
        case .timing: return .timing
        case .sync: return .sync
        }
    }

    var glyph: PixelGlyph {
        switch self {
        case .subtitles: return .subtitles
        case .audio: return .audio
        case .speed: return .speed
        case .aspect: return .aspect
        case .translate: return .translate
        case .timing: return .timer
        case .sync: return .sync
        }
    }

    var title: String {
        switch self {
        case .subtitles: return "Subtitles"
        case .audio: return "Audio"
        case .speed: return "Speed"
        case .aspect: return "Aspect"
        case .translate: return "Translate"
        case .timing: return "Timing"
        case .sync: return "Sync"
        }
    }

    var identifier: String {
        switch self {
        case .subtitles: return AX.Player.subtitlesButton
        case .audio: return AX.Player.audioButton
        case .speed: return AX.Player.speedButton
        case .aspect: return AX.Player.aspectButton
        case .translate: return AX.Player.translateButton
        case .timing: return AX.Player.timingButton
        case .sync: return AX.Player.syncButton
        }
    }
}

/// The tool buttons: one compact row over the video (landscape) or a grid on black (portrait).
struct ToolStrip: View {
    let session: PlayerSession
    var compact: Bool
    let onTool: (PlayerSheet) -> Void

    var body: some View {
        if compact {
            HStack(spacing: 0) {
                ForEach(PlayerTool.allCases) { tool in button(tool) }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 4),
                      spacing: Spacing.xs) {
                ForEach(PlayerTool.allCases) { tool in button(tool) }
            }
        }
    }

    private func button(_ tool: PlayerTool) -> some View {
        ToolButton(tool: tool, value: value(for: tool), isActive: isActive(tool),
                   isEnabled: session.isLoaded || tool == .subtitles, compact: compact) {
            onTool(tool.sheet)
        }
    }

    private func value(for tool: PlayerTool) -> String? {
        switch tool {
        case .subtitles:
            guard let active = session.activeSubtitle else { return "Off" }
            return active.descriptor.language?.primary.uppercased() ?? "On"
        case .audio:
            guard session.audioTracks.count > 1,
                  let index = session.audioTracks.firstIndex(where: { $0.id == session.selectedAudioTrackID }) else { return nil }
            return "\(index + 1)/\(session.audioTracks.count)"
        case .speed:
            return SpeedSheet.label(session.rate)
        case .aspect:
            return session.aspectMode.label
        case .timing:
            return session.timing.isIdentity ? nil : TimecodeFormatter.signedOffset(session.timing.offset)
        case .translate, .sync:
            return nil
        }
    }

    private func isActive(_ tool: PlayerTool) -> Bool {
        switch tool {
        case .subtitles: return session.activeSubtitle != nil
        case .speed: return abs(session.rate - 1) > 0.001
        case .aspect: return session.aspectMode != .fit
        case .timing: return !session.timing.isIdentity
        case .audio, .translate, .sync: return false
        }
    }
}

struct ToolButton: View {
    let tool: PlayerTool
    let value: String?
    let isActive: Bool
    let isEnabled: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xxs) {
                PixelIcon(tool.glyph, size: compact ? 18 : 22, color: isActive ? Palette.accent : Palette.textPrimary)
                Text(tool.title.uppercased())
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !compact {
                    Text(value ?? " ")
                        .font(Typo.mono)
                        .foregroundStyle(isActive ? Palette.accent : Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? Spacing.touch + 4 : 76)
            .contentShape(Rectangle())
            .background(compact ? nil : PixelRect().fill(Palette.surface))
            .overlay(compact ? nil : PixelRect().stroke(isActive ? Palette.accent.opacity(0.6) : Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(tool.title + (value.map { ", \($0)" } ?? ""))
        .accessibilityIdentifier(tool.identifier)
    }
}

/// Below the video in portrait: title, what's playing, and the tool grid within thumb reach.
struct PortraitPanel: View {
    let session: PlayerSession
    let onTool: (PlayerSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(session.item.title)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier(AX.Player.title)
                HStack(spacing: 6) {
                    if let kind = session.engineKind {
                        PixelTag(kind.displayName)
                            .accessibilityIdentifier(AX.Player.engineTag)
                    }
                    if let active = session.activeSubtitle {
                        Text(active.descriptor.title)
                            .font(Typo.callout)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("Subtitles off").font(Typo.callout).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            ToolStrip(session: session, compact: false, onTool: onTool)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
