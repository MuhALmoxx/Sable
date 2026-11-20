import SwiftUI
import UIKit
import LibraryKit

// OWNER: library agent.

/// 16:9 thumbnail with a 1-px border; a film glyph while none exists.
struct LibraryThumbnail: View {
    let image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Palette.surface)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    PixelIcon(.film, size: 22, color: Palette.textTertiary)
                }
            }
            .clipped()
            .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Title text that switches to IBM Plex Sans Arabic (right-to-left) for Arabic titles.
struct LibraryTitleText: View {
    let title: String
    var lineLimit = 2

    var body: some View {
        if LibraryFormat.containsArabic(title) {
            // Inside the right-to-left environment "leading" is the right edge.
            Text("\u{200F}" + title)
                .font(Typo.arabic)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
        } else {
            Text(title)
                .font(Typo.headline)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "12:31 · [MKV] · Played 2 days ago", wrapping to a stack at large text sizes.
struct LibraryMetaLine: View {
    let item: MediaItem

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { parts(separated: true) }
            VStack(alignment: .leading, spacing: 4) { parts(separated: false) }
        }
    }

    @ViewBuilder
    private func parts(separated: Bool) -> some View {
        Text(item.duration.map(LibraryFormat.clock) ?? "--:--")
            .font(Typo.mono)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
        if separated { dot }
        PixelTag(LibraryFormat.containerTag(item), tint: Palette.textTertiary)
        if let played = item.lastPlayedAt {
            if separated { dot }
            Text(LibraryFormat.lastPlayed(played))
                .font(Typo.callout)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        }
    }

    private var dot: some View {
        Text("·").font(Typo.callout).foregroundStyle(Palette.textTertiary)
    }
}

/// Thin watch-progress bar plus the "Resume 12:31" hint.
struct LibraryProgressInfo: View {
    let item: MediaItem
    let showResumeHint: Bool

    var body: some View {
        let fraction = item.progressFraction
        if fraction > 0 || (showResumeHint && LibraryFormat.resumePosition(item) != nil) {
            VStack(alignment: .leading, spacing: 4) {
                if showResumeHint, let position = LibraryFormat.resumePosition(item) {
                    Text("Resume \(LibraryFormat.clock(position))")
                        .font(Typo.callout)
                        .foregroundStyle(Palette.textSecondary)
                } else if item.playback.completed {
                    Text("Watched")
                        .font(Typo.callout)
                        .foregroundStyle(Palette.textTertiary)
                }
                if fraction > 0 {
                    PixelProgressBar(value: fraction, height: 3)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// One library list row: thumbnail left, text right. The whole row plays the video.
struct LibraryRow: View {
    let item: MediaItem
    let thumbnail: UIImage?
    let showResumeHint: Bool
    let onPlay: () -> Void

    @ScaledMetric(relativeTo: .body) private var thumbnailWidth: CGFloat = 128

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                LibraryThumbnail(image: thumbnail)
                    .frame(width: min(thumbnailWidth, 180))
                VStack(alignment: .leading, spacing: Spacing.xxs + 2) {
                    LibraryTitleText(title: item.title)
                    LibraryMetaLine(item: item)
                    LibraryProgressInfo(item: item, showResumeHint: showResumeHint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LibraryFormat.accessibilityLabel(for: item))
        .accessibilityHint("Plays the video")
        .accessibilityIdentifier(AX.Library.item(item.title))
    }
}

/// Compact grid cell: thumbnail on top, title and meta below.
struct LibraryGridCell: View {
    let item: MediaItem
    let thumbnail: UIImage?
    let showResumeHint: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ZStack(alignment: .bottom) {
                    LibraryThumbnail(image: thumbnail)
                    if item.progressFraction > 0 {
                        PixelProgressBar(value: item.progressFraction, height: 3)
                            .padding(1)
                            .accessibilityHidden(true)
                    }
                }
                LibraryTitleText(title: item.title, lineLimit: 2)
                HStack(spacing: 6) {
                    Text(item.duration.map(LibraryFormat.clock) ?? "--:--")
                        .font(Typo.mono)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    PixelTag(LibraryFormat.containerTag(item), tint: Palette.textTertiary)
                }
                if showResumeHint, let position = LibraryFormat.resumePosition(item) {
                    Text("Resume \(LibraryFormat.clock(position))")
                        .font(Typo.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LibraryFormat.accessibilityLabel(for: item))
        .accessibilityHint("Plays the video")
        .accessibilityIdentifier(AX.Library.item(item.title))
    }
}

/// Progress/error row for one file being imported.
struct ImportJobRow: View {
    let job: ImportCoordinator.Job
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            PixelIcon(glyph, size: 18, color: tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: Spacing.xxs + 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(job.fileName)
                        .font(Typo.bodyMedium)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Spacing.xs)
                    Text(job.phase.label.uppercased())
                        .font(Typo.micro)
                        .tracking(1)
                        .foregroundStyle(tint)
                }
                switch job.phase {
                case let .failed(message), let .warning(message):
                    Text(message)
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    PixelProgressBar(value: job.phase.fraction, height: 3)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            if case .failed = job.phase {
                PixelIconButton(.close, label: "Dismiss", size: 12, action: onDismiss)
            } else if case .warning = job.phase {
                PixelIconButton(.close, label: "Dismiss", size: 12, action: onDismiss)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityIdentifier(AX.Library.importJob)
    }

    private var glyph: PixelGlyph {
        switch job.phase {
        case .failed: return .warning
        case .warning: return .info
        case .done: return .check
        default: return .importFile
        }
    }

    private var tint: Color {
        switch job.phase {
        case .failed: return Palette.danger
        case .done: return Palette.success
        case .warning: return Palette.textSecondary
        default: return Palette.accent
        }
    }
}
