import SwiftUI

// OWNER: library agent.

/// One open-source component shipped in the app.
struct OpenSourceComponent: Identifiable, Hashable {
    let id: String
    let name: String
    let license: String
    let summary: String
    /// Extra obligations/explanations shown above the license text.
    let notes: [String]
    let text: String

    static let all: [OpenSourceComponent] = [
        OpenSourceComponent(
            id: "sable",
            name: "Sable",
            license: "MIT License",
            summary: "This app. Source code: github.com/MuhALmoxx/Sable",
            notes: ["Sable's own source code is open source under the MIT License: https://github.com/MuhALmoxx/Sable"],
            text: LicenseTexts.sableMIT
        ),
        OpenSourceComponent(
            id: "mobilevlckit",
            name: "MobileVLCKit 3.7.5",
            license: "GNU LGPL 2.1",
            summary: "VLC playback engine for MKV, WebM, AVI and other formats. Dynamically linked.",
            notes: [
                "MobileVLCKit (VLCKit with libVLC) is licensed under the GNU Lesser General Public License, version 2.1. Sable does not modify it.",
                "It is dynamically linked: it ships as a separate framework inside the app bundle (Sable.app/Frameworks/MobileVLCKit.framework) and Sable only uses its public API.",
                "Source code: https://code.videolan.org/videolan/VLCKit (the exact 3.7.5 release Sable uses is listed in scripts/fetch-vlckit.sh in Sable's repository).",
                "How to relink with your own version: build MobileVLCKit from that source (or a modified copy), place your MobileVLCKit.xcframework in Vendor/ of the Sable source tree, and rebuild Sable with Xcode — or replace Frameworks/MobileVLCKit.framework inside the built app with your own build and re-sign the app.",
            ],
            text: LicenseTexts.mobileVLCKitLGPL21
        ),
        OpenSourceComponent(
            id: "pixelify-sans",
            name: "Pixelify Sans",
            license: "SIL Open Font License 1.1",
            summary: "Pixel typeface for the interface.",
            notes: [],
            text: LicenseTexts.pixelifySansOFL
        ),
        OpenSourceComponent(
            id: "silkscreen",
            name: "Silkscreen",
            license: "SIL Open Font License 1.1",
            summary: "Micro labels.",
            notes: [],
            text: LicenseTexts.silkscreenOFL
        ),
        OpenSourceComponent(
            id: "ibm-plex-sans-arabic",
            name: "IBM Plex Sans Arabic",
            license: "SIL Open Font License 1.1",
            summary: "Arabic and reading text, Arabic subtitles.",
            notes: [],
            text: LicenseTexts.ibmPlexSansArabicOFL
        ),
    ]
}

struct LicensesScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SettingsScreenHeader(title: "Licenses") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Sable is built with these open-source components. Tap one to read its full license.")
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(OpenSourceComponent.all.enumerated()), id: \.element.id) { index, component in
                            if index > 0 { SettingsDivider() }
                            NavigationLink {
                                LicenseDetailScreen(component: component)
                            } label: {
                                LicenseRow(component: component)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AX.Settings.license(component.id))
                        }
                    }
                    .pixelPanel(fill: Palette.surface)
                }
                .padding(Spacing.md)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Settings.licensesScreen)
    }
}

private struct LicenseRow: View {
    let component: OpenSourceComponent

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text(component.name)
                    .font(Typo.bodyMedium)
                    .foregroundStyle(Palette.textPrimary)
                PixelTag(component.license, tint: Palette.textSecondary)
                Text(component.summary)
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PixelIcon(.chevronRight, size: 14, color: Palette.textTertiary)
        }
        .padding(Spacing.md)
        .frame(minHeight: Spacing.touch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct LicenseDetailScreen: View {
    let component: OpenSourceComponent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SettingsScreenHeader(title: component.name) { dismiss() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                    PixelTag(component.license, tint: Palette.textSecondary)
                    ForEach(Array(component.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(Typo.reading)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !component.notes.isEmpty { SettingsDivider().padding(.vertical, Spacing.xs) }
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(Spacing.md)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Paragraph chunks keep very long texts (LGPL) fast to lay out in a lazy stack.
    private var paragraphs: [String] {
        component.text.components(separatedBy: "\n\n")
    }
}
