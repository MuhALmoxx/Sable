import SwiftUI
import LibraryKit

// OWNER: library agent (settings + about/licenses).
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SettingsScreenHeader(title: "Settings") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    PlaybackSettingsSection(settings: services.settings)
                    SubtitleSettingsSection(settings: services.settings)
                    TranslationSettingsSection()
                    StorageSettingsSection()
                    AboutSettingsSection()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xxl)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Settings.screen)
    }
}

// MARK: - Playback

struct PlaybackSettingsSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsGroup("Playback") {
            SettingsItem("Skip interval", detail: "Double-tap the left or right side of the video, or use the skip buttons.") {
                SettingsSegmented(options: AppSettings.doubleTapOptions, selection: $settings.doubleTapSeekSeconds,
                                  label: { "\(Int($0)) s" },
                                  accessibilityLabelFor: { "\(Int($0)) seconds" },
                                  axID: AX.Settings.doubleTap)
            }
            SettingsDivider()
            SettingsItem("Default speed", detail: "Used when a video has no speed of its own yet.") {
                let options = AppSettings.rateOptions
                let index = options.firstIndex(of: settings.defaultRate) ?? options.firstIndex(of: 1) ?? 0
                SettingsStepper(
                    valueText: Self.rateLabel(settings.defaultRate),
                    accessibilityLabel: "Default speed",
                    canDecrement: index > 0,
                    canIncrement: index < options.count - 1,
                    decrement: { if index > 0 { settings.defaultRate = options[index - 1] } },
                    increment: { if index < options.count - 1 { settings.defaultRate = options[index + 1] } },
                    axID: AX.Settings.defaultSpeed
                )
            }
            SettingsDivider()
            SettingsToggleRow(title: "Resume where I left off",
                              detail: "Reopening a video continues from the last position.",
                              isOn: $settings.resumePlayback,
                              axID: AX.Settings.resume)
            SettingsDivider()
            SettingsToggleRow(title: "Use VLC engine for every file",
                              detail: "Also plays MP4 and MOV with VLC. Picture in Picture is not available then.",
                              isOn: $settings.preferVLCForAll,
                              axID: AX.Settings.vlcForAll)
        }
    }

    static func rateLabel(_ rate: Float) -> String {
        let rounded = (Double(rate) * 100).rounded() / 100
        if rounded == rounded.rounded() { return "\(Int(rounded))×" }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text + "×"
    }
}

// MARK: - Subtitles

struct SubtitleSettingsSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsGroup("Subtitles", footer: "These are the defaults. A video can keep its own subtitle style from the player.") {
            SubtitlePreview(style: settings.subtitleStyle)
                .padding(Spacing.md)
            SettingsDivider()
            SettingsItem("Size") {
                let scale = settings.subtitleStyle.scale
                let range = AppSettings.subtitleScaleRange
                SettingsStepper(
                    valueText: "\(Int((scale * 100).rounded()))%",
                    accessibilityLabel: "Subtitle size",
                    canDecrement: scale > range.lowerBound + 0.001,
                    canIncrement: scale < range.upperBound - 0.001,
                    decrement: { setScale(scale - AppSettings.subtitleScaleStep) },
                    increment: { setScale(scale + AppSettings.subtitleScaleStep) },
                    axID: AX.Settings.subtitleSize
                )
            }
            SettingsDivider()
            SettingsItem("Background") {
                SettingsSegmented(options: SubtitleBackground.allCases, selection: $settings.subtitleStyle.background,
                                  label: Self.backgroundLabel, axID: AX.Settings.subtitleBackground)
            }
            SettingsDivider()
            SettingsItem("Font", detail: "Pixel applies to Latin text only. Arabic always uses IBM Plex Sans Arabic for correct shaping.") {
                SettingsSegmented(options: SubtitleFontChoice.allCases, selection: $settings.subtitleStyle.font,
                                  label: Self.fontLabel, axID: AX.Settings.subtitleFont)
            }
            SettingsDivider()
            SettingsToggleRow(title: "Show original under translation",
                              detail: "When an Arabic translation is on, the English line appears underneath in smaller type.",
                              isOn: $settings.subtitleStyle.showOriginalUnderTranslation,
                              axID: AX.Settings.showOriginal)
        }
    }

    private func setScale(_ value: Double) {
        let range = AppSettings.subtitleScaleRange
        let stepped = (value * 10).rounded() / 10
        settings.subtitleStyle.scale = min(range.upperBound, max(range.lowerBound, stepped))
    }

    static func backgroundLabel(_ background: SubtitleBackground) -> String {
        switch background {
        case .outline: return "Outline"
        case .shadow: return "Shadow"
        case .box: return "Box"
        }
    }

    static func fontLabel(_ font: SubtitleFontChoice) -> String {
        switch font {
        case .plex: return "Plex"
        case .system: return "System"
        case .pixel: return "Pixel"
        }
    }
}

// MARK: - About

struct AboutSettingsSection: View {
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        SettingsGroup("About") {
            SettingsValueRow(title: "Version", value: versionText, axID: AX.Settings.version)
            SettingsDivider()
            SettingsValueRow(title: "Engines",
                             value: "AVFoundation for MP4, MOV and M4V (hardware decoding, Picture in Picture). VLC (MobileVLCKit 3.7.5) for MKV, WebM, AVI and everything else.")
            SettingsDivider()
            SettingsValueRow(title: "Formats",
                             value: "Video: MP4, MOV, M4V, MKV, WebM, AVI, TS and more. Subtitles: SRT, WebVTT, ASS/SSA files and embedded text tracks; image-based PGS/VobSub tracks display with VLC.")
            SettingsDivider()
            NavigationLink {
                LicensesScreen()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text("Open-source licenses")
                        .font(Typo.bodyMedium)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    PixelIcon(.chevronRight, size: 14, color: Palette.textTertiary)
                }
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: Spacing.touch + Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open-source licenses")
            .accessibilityIdentifier(AX.Settings.licenses)
        }
    }
}
