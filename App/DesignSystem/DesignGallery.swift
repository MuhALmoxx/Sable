import SwiftUI

// OWNER: design agent. Every design-system component on one scrollable screen, for Xcode
// previews and QA screenshots. Not linked from the app's navigation.

struct DesignGallery: View {
    @State private var autoPlay = true
    @State private var subtitleScale = 1.0
    @State private var speed = "1×"
    @State private var apiKey = ""
    @State private var toast: PixelToastItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text("Sable").font(Typo.display).foregroundStyle(Palette.textPrimary)
                buttons
                controls
                feedback
                list
                emptyStates
                glyphs
            }
            .padding(Spacing.md)
        }
        .background(Palette.background.ignoresSafeArea())
        .pixelToast($toast)
    }

    private var buttons: some View {
        section("Buttons") {
            Button("Translate track") {}
                .buttonStyle(PixelButtonStyle(kind: .primary))
            HStack(spacing: Spacing.xs) {
                Button("Secondary") {}.buttonStyle(PixelButtonStyle())
                Button("Ghost") {}.buttonStyle(PixelButtonStyle(kind: .ghost))
                Button("Delete") {}.buttonStyle(PixelButtonStyle(kind: .destructive, compact: true))
            }
            Button("Disabled") {}
                .buttonStyle(PixelButtonStyle())
                .disabled(true)
            HStack(spacing: 0) {
                PixelIconButton(.play, label: "Play") {}
                PixelIconButton(.subtitles, label: "Subtitles", isActive: true) {}
                PixelIconButton(.lock, label: "Lock controls") {}.disabled(true)
            }
        }
    }

    private var controls: some View {
        section("Controls") {
            PixelToggle("Resume where I left off", subtitle: "Per video", isOn: $autoPlay)
            PixelSegmented("Playback speed", selection: $speed, options: ["0.5×", "1×", "1.5×", "2×"],
                           title: { $0 })
            PixelSlider("Subtitle size", value: $subtitleScale, in: 0.5...2, step: 0.25,
                        valueText: { String(format: "%.2f×", $0) })
            PixelTextField("API key", text: $apiKey, prompt: "Paste key", isSecure: true,
                           message: "Stored in the Keychain only.")
        }
    }

    private var feedback: some View {
        section("Feedback") {
            HStack(spacing: Spacing.md) {
                PixelSpinner()
                PixelProgressBar(value: 0.42)
            }
            PixelToast(PixelToastItem("Translation saved", kind: .success))
            Button("Show toast") {
                toast = PixelToastItem("Offset +2.5 s applied", actionTitle: "Undo", action: {})
            }
            .buttonStyle(PixelButtonStyle(compact: true))
        }
    }

    private var list: some View {
        section("List") {
            VStack(spacing: 0) {
                PixelListRow(glyph: .subtitles, title: "English", subtitle: "SRT · embedded", isActive: true) {
                    PixelAccessory.check(true)
                }
                PixelDivider(inset: Spacing.md)
                PixelListRow(glyph: .translate, title: "العربية", subtitle: "Translated from English") {
                    PixelAccessory.tag("AR")
                }
                PixelDivider(style: .dotted, inset: Spacing.md)
                PixelListRow(glyph: .settings, title: "Settings") {
                    PixelAccessory.chevron
                }
            }
            .pixelPanel()
        }
    }

    private var emptyStates: some View {
        section("Empty states") {
            HStack(alignment: .bottom, spacing: Spacing.lg) {
                PixelEmptyArt(.library, pixelSize: 3)
                PixelEmptyArt(.player, pixelSize: 3)
                PixelEmptyArt(.subtitles, pixelSize: 3)
            }
            PixelMessage(glyph: .film, title: "No videos yet", message: "Import a video from Files to start.",
                         actionTitle: "Import video", action: {})
        }
    }

    private var glyphs: some View {
        section("Glyphs", trailing: "\(PixelGlyph.allCases.count)") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: Spacing.sm) {
                ForEach(PixelGlyph.allCases, id: \.self) { glyph in
                    PixelIcon(glyph, size: Spacing.icon, color: Palette.textPrimary)
                        .frame(height: Spacing.touch)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, trailing: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel(title, trailing: trailing)
            content()
        }
    }
}

#Preview {
    DesignGallery()
        .preferredColorScheme(.dark)
}
