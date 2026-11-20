import SwiftUI
import SubtitleKit
import LibraryKit

// OWNER: playback agent. Subtitle + audio track picker presented from the player.
struct TrackSheet: View {
    let session: PlayerSession
    var onClose: () -> Void = {}

    @State private var showingPicker = false
    @State private var isImporting = false
    @State private var importMessage: String?

    var body: some View {
        PixelSheet(title: "Subtitles", subtitle: summary, onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    subtitleSection
                    importSection
                    SubtitleStyleControls(session: session)
                    AudioTrackList(session: session)
                }
                .padding(Spacing.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Tracks.sheet)
        .sheet(isPresented: $showingPicker) {
            SubtitleDocumentPicker(onPick: { url in
                showingPicker = false
                importFile(url)
            }, onCancel: {
                showingPicker = false
            })
            .ignoresSafeArea()
        }
    }

    private var summary: String {
        if let active = session.activeSubtitle { return "Showing: \(active.descriptor.title)" }
        return "Subtitles are off"
    }

    // MARK: Subtitles

    private var embedded: [SubtitleTrackDescriptor] {
        session.subtitleTracks.filter { if case .embedded = $0.origin { return true } else { return false } }
    }

    private var external: [SubtitleTrackDescriptor] {
        session.subtitleTracks.filter { if case .external = $0.origin { return true } else { return false } }
    }

    private var translated: [SubtitleTrackDescriptor] {
        session.subtitleTracks.filter { if case .translated = $0.origin { return true } else { return false } }
    }

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Subtitles", trailing: "\(session.subtitleTracks.count) tracks")
            if case let .failed(message) = session.subtitleLoadState {
                InlineMessage(glyph: .warning, text: message, tint: Palette.danger)
            }
            TrackRow(title: "Off",
                     isActive: session.activeSubtitle == nil && session.loadingSubtitleTrackID == nil,
                     identifier: AX.Tracks.subtitleOff) {
                Task { await session.selectSubtitleTrack(nil) }
            }
            trackGroup("Embedded", tracks: embedded)
            trackGroup("External files", tracks: external)
            trackGroup("Translations", tracks: translated)
            if !session.unsupportedSubtitleTracks.isEmpty {
                SectionLabel("Not supported").padding(.top, Spacing.xs)
                ForEach(session.unsupportedSubtitleTracks, id: \.self) { label in
                    Text(label)
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func trackGroup(_ title: String, tracks: [SubtitleTrackDescriptor]) -> some View {
        if !tracks.isEmpty {
            SectionLabel(title).padding(.top, Spacing.xs)
            ForEach(tracks) { track in
                TrackRow(title: track.title,
                         detail: detail(for: track),
                         tags: Self.tags(for: track),
                         isActive: session.activeSubtitle?.descriptor.id == track.id,
                         isLoading: session.loadingSubtitleTrackID == track.id,
                         progress: progress,
                         identifier: AX.Tracks.subtitle(track.id)) {
                    Task { await session.selectSubtitleTrack(track.id) }
                }
            }
        }
    }

    private var progress: Double? {
        if case let .loading(progress) = session.subtitleLoadState { return progress }
        return nil
    }

    private func detail(for track: SubtitleTrackDescriptor) -> String? {
        guard track.kind == .image else { return nil }
        let codec = SubtitleRepository.imageCodecLabel(track)
        if session.engineKind == .vlc {
            return "Image-based (\(codec)): drawn by the VLC engine. It can't be translated or synced."
        }
        return "Image-based (\(codec)): needs the VLC engine. It can't be translated or synced."
    }

    static func tags(for track: SubtitleTrackDescriptor) -> [String] {
        var tags: [String] = []
        if let language = track.language { tags.append(language.primary.uppercased()) }
        if track.kind == .image {
            tags.append("IMAGE")
        } else if let format = formatTag(track.format) {
            tags.append(format)
        }
        if track.isDefault { tags.append("DEFAULT") }
        if track.isForced { tags.append("FORCED") }
        if case .translated = track.origin { tags.append("TRANSLATED") }
        return tags
    }

    static func formatTag(_ format: SubtitleFormat) -> String? {
        switch format {
        case .srt: return "SRT"
        case .webvtt: return "VTT"
        case .ass: return "ASS"
        case .ssa: return "SSA"
        case .tx3g: return "TX3G"
        case .unknown: return nil
        }
    }

    // MARK: Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                importMessage = nil
                showingPicker = true
            } label: {
                HStack(spacing: Spacing.xs) {
                    if isImporting {
                        PixelSpinner(size: 16)
                    } else {
                        PixelIcon(.importFile, size: 16)
                    }
                    Text(isImporting ? "Importing…" : "Import subtitle file…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .disabled(isImporting)
            .accessibilityLabel("Import subtitle file")
            .accessibilityHint("SRT, WebVTT, ASS or SSA from Files")
            .accessibilityIdentifier(AX.Tracks.importSubtitle)
            if let importMessage {
                InlineMessage(glyph: .warning, text: importMessage, tint: Palette.danger)
            }
        }
    }

    private func importFile(_ url: URL) {
        isImporting = true
        importMessage = nil
        Task {
            do {
                try await session.importExternalSubtitle(from: url)
            } catch {
                importMessage = readableMessage(for: error)
            }
            isImporting = false
        }
    }
}

/// Audio track list (also used by the player's Audio button).
struct AudioTrackList: View {
    let session: PlayerSession

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Audio", trailing: session.engineKind?.displayName)
            if session.audioTracks.isEmpty {
                Text(session.isLoaded ? "This video has a single audio track." : "Audio tracks appear once the video is open.")
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
            }
            ForEach(session.audioTracks) { track in
                TrackRow(title: track.title,
                         tags: tags(for: track),
                         isActive: track.id == session.selectedAudioTrackID,
                         identifier: AX.Tracks.audio(track.id)) {
                    session.selectAudioTrack(track.id)
                }
            }
        }
    }

    private func tags(for track: AudioTrackInfo) -> [String] {
        var tags: [String] = []
        if let language = track.language { tags.append(language.primary.uppercased()) }
        if track.isDefault { tags.append("DEFAULT") }
        return tags
    }
}

struct AudioTrackSheet: View {
    let session: PlayerSession
    var onClose: () -> Void = {}

    var body: some View {
        PixelSheet(title: "Audio", onClose: onClose) {
            ScrollView {
                AudioTrackList(session: session).padding(Spacing.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Tracks.audioSheet)
    }
}

/// Per-video subtitle style quick controls (size, background, font, original line).
struct SubtitleStyleControls: View {
    let session: PlayerSession

    var body: some View {
        let style = session.subtitleStyle
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel("Subtitle style", trailing: session.hasPerVideoStyle ? "This video" : "App default")

            HStack(spacing: Spacing.xs) {
                Text("Size").font(Typo.body).foregroundStyle(Palette.textPrimary)
                Spacer()
                PixelIconButton(.minus, label: "Smaller subtitles", size: 16) {
                    update { $0.scale = Self.step($0.scale, by: -0.1) }
                }
                .disabled(style.scale <= 0.6 + 0.001)
                .accessibilityIdentifier(AX.Tracks.styleSmaller)
                Text("\(Int((style.scale * 100).rounded()))%")
                    .font(Typo.mono)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(minWidth: 52)
                    .accessibilityLabel("Subtitle size \(Int((style.scale * 100).rounded())) percent")
                PixelIconButton(.plus, label: "Larger subtitles", size: 16) {
                    update { $0.scale = Self.step($0.scale, by: 0.1) }
                }
                .disabled(style.scale >= 2.0 - 0.001)
                .accessibilityIdentifier(AX.Tracks.styleLarger)
            }

            Text("Background").font(Typo.body).foregroundStyle(Palette.textPrimary)
            HStack(spacing: Spacing.xs) {
                ForEach(SubtitleBackground.allCases, id: \.self) { background in
                    OptionChip(label: Self.label(for: background), isSelected: style.background == background,
                               identifier: AX.Tracks.styleBackground(background.rawValue)) {
                        update { $0.background = background }
                    }
                }
            }

            Text("Font").font(Typo.body).foregroundStyle(Palette.textPrimary)
            HStack(spacing: Spacing.xs) {
                ForEach(SubtitleFontChoice.allCases, id: \.self) { font in
                    OptionChip(label: Self.label(for: font), isSelected: style.font == font,
                               identifier: AX.Tracks.styleFont(font.rawValue)) {
                        update { $0.font = font }
                    }
                }
            }
            if style.font == .pixel {
                Text("Pixel type is used for Latin text only; Arabic always uses IBM Plex Sans Arabic.")
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PixelToggleRow(title: "Show original under translation",
                           detail: "Adds the source line in smaller type below a translated line.",
                           isOn: style.showOriginalUnderTranslation,
                           identifier: AX.Tracks.showOriginal) {
                update { $0.showOriginalUnderTranslation.toggle() }
            }

            if session.hasPerVideoStyle {
                Button("Use app default style") { session.useDefaultSubtitleStyle() }
                    .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
                    .accessibilityIdentifier(AX.Tracks.styleDefault)
            }
        }
    }

    private func update(_ change: (inout SubtitleStyle) -> Void) {
        var style = session.subtitleStyle
        change(&style)
        session.updateSubtitleStyle(style)
    }

    static func step(_ value: Double, by delta: Double) -> Double {
        min(2.0, max(0.6, ((value + delta) * 10).rounded() / 10))
    }

    static func label(for background: SubtitleBackground) -> String {
        switch background {
        case .outline: return "Outline"
        case .shadow: return "Shadow"
        case .box: return "Box"
        }
    }

    static func label(for font: SubtitleFontChoice) -> String {
        switch font {
        case .plex: return "Plex"
        case .system: return "System"
        case .pixel: return "Pixel"
        }
    }
}

// MARK: - Rows and small controls

struct TrackRow: View {
    let title: String
    var detail: String? = nil
    var tags: [String] = []
    var isActive: Bool
    var isLoading: Bool = false
    var progress: Double? = nil
    var isEnabled: Bool = true
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(Typo.bodyMedium)
                        .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                PixelTag(tag, tint: tag == "IMAGE" ? Palette.accent : Palette.textSecondary)
                            }
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(Typo.reading)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isLoading {
                        if let progress {
                            HStack(spacing: Spacing.xs) {
                                PixelProgressBar(value: progress, height: 4)
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(Typo.mono)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .padding(.top, 2)
                        } else {
                            Text("Loading…").font(Typo.callout).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                Spacer(minLength: Spacing.xs)
                if isLoading {
                    PixelSpinner(size: 16)
                } else if isActive {
                    PixelIcon(.check, size: 18, color: Palette.accent)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.touch)
            .contentShape(Rectangle())
            .pixelPanel(fill: isActive ? Palette.accentDim : Palette.surface,
                        border: isActive ? Palette.accent : Palette.border)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    private var accessibilityText: String {
        var parts = [title]
        parts.append(contentsOf: tags)
        if let detail { parts.append(detail) }
        if isLoading { parts.append(progress.map { "Loading \(Int(($0 * 100).rounded())) percent" } ?? "Loading") }
        return parts.joined(separator: ", ")
    }
}

struct OptionChip: View {
    let label: String
    let isSelected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Typo.callout)
                .foregroundStyle(isSelected ? Palette.accent : Palette.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .frame(minWidth: Spacing.touch, minHeight: Spacing.touch)
                .contentShape(Rectangle())
                .pixelPanel(fill: isSelected ? Palette.accentDim : Palette.surfaceRaised,
                            border: isSelected ? Palette.accent : Palette.border)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

struct PixelToggleRow: View {
    let title: String
    var detail: String? = nil
    let isOn: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                ZStack {
                    Rectangle().fill(isOn ? Palette.accent : Color.clear)
                    Rectangle().stroke(isOn ? Palette.accent : Palette.borderStrong, lineWidth: 1)
                    if isOn { PixelIcon(.check, size: 14, color: Palette.onAccent) }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.body).foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail).font(Typo.reading).foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// One-line status message (warnings, errors) inside sheets and over the video.
struct InlineMessage: View {
    let glyph: PixelGlyph
    let text: String
    var tint: Color = Palette.textSecondary

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            PixelIcon(glyph, size: 14, color: tint)
            Text(text)
                .font(Typo.reading)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(fill: Palette.surface, border: tint.opacity(0.6))
        .accessibilityElement(children: .combine)
    }
}
