import SwiftUI
import LibraryKit

// OWNER: library agent (app shell).

struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        // Captured so a late write from a sheet that is going away cancels only its own file.
        let pendingURL = services.playingItemID == nil ? services.pendingSubtitleFiles.first : nil
        NavigationStack {
            LibraryScreen()
        }
        .fullScreenCover(item: Binding(
            get: { services.playingItemID.map(IdentifiedUUID.init) },
            set: { services.playingItemID = $0?.id }
        )) { identified in
            PlayerScreen(itemID: identified.id)
                .overlay(alignment: .top) { BannerToastHost() }
                .environment(services)
        }
        .sheet(item: Binding(
            get: { services.playingItemID == nil ? services.pendingSubtitleFiles.first.map(IdentifiedURL.init) : nil },
            set: { if $0 == nil, let pendingURL { services.cancelPendingSubtitle(pendingURL) } }
        )) { pending in
            SubtitleTargetSheet(
                fileName: pending.url.lastPathComponent,
                items: LibraryQuery.apply(services.library.items, search: "", sort: .recentlyPlayed),
                onChoose: { services.attachPendingSubtitle(pending.url, to: $0) },
                onCancel: { services.cancelPendingSubtitle(pending.url) }
            )
            .environment(services)
        }
        .overlay(alignment: .top) { BannerToastHost() }
        .background(Palette.background.ignoresSafeArea())
    }
}

struct IdentifiedUUID: Identifiable, Hashable {
    let id: UUID
}

struct IdentifiedURL: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// Shows `services.banner` as a pixel toast at the top; auto-dismisses after a few seconds.
struct BannerToastHost: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack {
            if let message = services.banner {
                BannerToast(message: message) { services.banner = nil }
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        AccessibilityNotification.Announcement(message).post()
                        try? await Task.sleep(for: .seconds(BannerToast.duration(for: message)))
                        if services.banner == message { services.banner = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: services.banner)
    }
}

struct BannerToast: View {
    let message: String
    let onDismiss: () -> Void

    /// Long messages stay longer (reading time), between 4 and 10 seconds.
    static func duration(for message: String) -> Double {
        min(10, max(4, Double(message.count) / 15))
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            PixelIcon(.info, size: 16, color: Palette.accent)
                .padding(.top, 2)
            Text(message)
                .font(Typo.reading)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            PixelIconButton(.close, label: "Dismiss message", size: 12, action: onDismiss)
                .padding(.top, -Spacing.sm)
                .padding(.trailing, -Spacing.sm)
        }
        .padding(.leading, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .padding(.trailing, Spacing.xs)
        .frame(maxWidth: 560)
        .pixelPanel(fill: Palette.surfaceHigh, border: Palette.borderStrong)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.banner)
    }
}
