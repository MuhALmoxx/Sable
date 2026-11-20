import SwiftUI
import LibraryKit

// OWNER: library agent.

/// Asks which video a subtitle file opened from another app belongs to.
struct SubtitleTargetSheet: View {
    let fileName: String
    let items: [MediaItem]
    let onChoose: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        PixelSheet(title: "Add subtitle", subtitle: fileName, onClose: onCancel) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Choose the video")
                        .padding(.horizontal, Spacing.md)
                        .padding(.top, Spacing.md)
                        .padding(.bottom, Spacing.xs)
                    ForEach(items) { item in
                        Button { onChoose(item.id) } label: {
                            HStack(spacing: Spacing.sm) {
                                VStack(alignment: .leading, spacing: 4) {
                                    LibraryTitleText(title: item.title, lineLimit: 2)
                                    LibraryMetaLine(item: item)
                                }
                                PixelIcon(.chevronRight, size: 14, color: Palette.textTertiary)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .frame(minHeight: Spacing.touch)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityHint("Adds the subtitle file to this video")
                        .accessibilityIdentifier(AX.Library.subtitleTarget(item.title))
                        Rectangle().fill(Palette.border).frame(height: 1)
                            .padding(.leading, Spacing.md)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.background)
        .accessibilityIdentifier(AX.Library.subtitleTargetSheet)
    }
}
