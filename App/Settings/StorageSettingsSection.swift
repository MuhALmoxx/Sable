import SwiftUI
import LibraryKit

// OWNER: library agent.

/// Library size on disk and cache clearing.
struct StorageSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var usage: LibraryStore.StorageUsage?
    @State private var isWorking = false
    @State private var status: String?

    var body: some View {
        SettingsGroup("Storage", footer: "Clearing caches never deletes videos, imported subtitles or translations. Thumbnails are redrawn and embedded subtitles re-read when needed.") {
            if let usage {
                SettingsValueRow(title: "Total", value: LibraryFormat.byteCount(usage.total), axID: AX.Settings.storageTotal)
                ForEach(Self.breakdown(usage), id: \.title) { line in
                    SettingsDivider()
                    SettingsValueRow(title: line.title, value: LibraryFormat.byteCount(line.bytes))
                }
            } else {
                SettingsValueRow(title: "Total", value: "Measuring…", axID: AX.Settings.storageTotal)
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) { buttons }
                    VStack(alignment: .leading, spacing: Spacing.xs) { buttons }
                }
                if let status {
                    Text(status)
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.md)
        }
        .task { await refresh() }
    }

    private struct StorageLine: Hashable {
        let title: String
        let bytes: Int64
    }

    private static func breakdown(_ usage: LibraryStore.StorageUsage) -> [StorageLine] {
        [
            StorageLine(title: "Videos", bytes: usage.media),
            StorageLine(title: "Subtitles and translations", bytes: usage.subtitles),
            StorageLine(title: "Translation progress", bytes: usage.translations),
            StorageLine(title: "Thumbnails", bytes: usage.thumbnails),
            StorageLine(title: "Subtitle extraction cache", bytes: usage.extracted),
        ]
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Clear thumbnails") { clearThumbnails() }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .disabled(isWorking || (usage?.thumbnails ?? 1) == 0)
            .accessibilityIdentifier(AX.Settings.clearThumbnails)
        Button("Clear subtitle cache") { clearExtractionCache() }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .disabled(isWorking || (usage?.extracted ?? 1) == 0)
            .accessibilityIdentifier(AX.Settings.clearSubtitleCache)
    }

    private func refresh() async {
        let root = services.library.root
        let measured = await Task.detached(priority: .utility) {
            LibraryStore.measureStorage(root: root)
        }.value
        usage = measured
    }

    private func clearThumbnails() {
        isWorking = true
        defer { isWorking = false }
        let freed = usage?.thumbnails ?? 0
        do {
            try services.library.clearThumbnails()
            services.imports.resetRepairAttempts()
            services.libraryDidChange()
            status = "Cleared \(LibraryFormat.byteCount(freed)) of thumbnails."
        } catch {
            status = "Could not clear thumbnails: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    private func clearExtractionCache() {
        isWorking = true
        defer { isWorking = false }
        let freed = usage?.extracted ?? 0
        do {
            try services.library.clearExtractionCache()
            status = "Cleared \(LibraryFormat.byteCount(freed)) of extracted subtitles."
        } catch {
            status = "Could not clear the subtitle cache: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }
}
