import SwiftUI

// OWNER: library agent.

/// First-run state: a small pixel scene (folder -> screen), one line of explanation, the primary
/// import button and the supported formats.
struct LibraryEmptyState<Action: View>: View {
    @ViewBuilder let action: () -> Action

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                EmptyLibraryIllustration()
                    .padding(.top, Spacing.xxl)
                VStack(spacing: Spacing.xs) {
                    Text("Your library is empty")
                        .font(Typo.title)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Import videos from Files, iCloud Drive or any connected storage. Sable keeps its own copy, so they play offline.")
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                action()
                Text("MKV · MP4 · MOV · WEBM · AVI and more. Subtitles: SRT, VTT, ASS.")
                    .font(Typo.micro)
                    .tracking(0.5)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Plays MKV, MP4, MOV, WebM, AVI and more. Subtitle files: SRT, VTT and ASS.")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.emptyState)
    }
}

/// Folder, an arrow of pixel steps, and a framed screen with a play glyph.
struct EmptyLibraryIllustration: View {
    var body: some View {
        HStack(spacing: Spacing.sm) {
            PixelIcon(.folder, size: 40, color: Palette.textTertiary)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Rectangle()
                        .fill(Palette.textTertiary.opacity(0.4 + 0.2 * Double(index)))
                        .frame(width: 4, height: 4)
                }
                PixelIcon(.chevronRight, size: 14, color: Palette.textSecondary)
            }
            ZStack {
                PixelRect(step: Spacing.px)
                    .fill(Palette.surface)
                PixelRect(step: Spacing.px)
                    .stroke(Palette.borderStrong, lineWidth: 1)
                PixelIcon(.play, size: 26, color: Palette.textSecondary)
            }
            .frame(width: 112, height: 63)
            .overlay(alignment: .bottom) {
                // A short pixel "subtitle" line under the play glyph.
                HStack(spacing: 3) {
                    Rectangle().fill(Palette.textTertiary).frame(width: 22, height: 3)
                    Rectangle().fill(Palette.textTertiary).frame(width: 14, height: 3)
                }
                .padding(.bottom, 8)
            }
        }
        .accessibilityHidden(true)
    }
}
