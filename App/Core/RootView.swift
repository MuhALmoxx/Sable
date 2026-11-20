import SwiftUI

// OWNER: library agent (app shell).

struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services
        NavigationStack {
            LibraryScreen()
        }
        .fullScreenCover(item: Binding(
            get: { services.playingItemID.map(IdentifiedUUID.init) },
            set: { services.playingItemID = $0?.id }
        )) { identified in
            PlayerScreen(itemID: identified.id)
                .environment(services)
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

struct IdentifiedUUID: Identifiable, Hashable {
    let id: UUID
}
