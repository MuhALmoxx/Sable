import SwiftUI

// OWNER: playback agent.
struct PlayerScreen: View {
    let itemID: UUID
    @Environment(AppServices.self) private var services

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            Text("Player").font(Typo.title).foregroundStyle(Palette.textPrimary)
        }
        .accessibilityIdentifier(AX.Player.screen)
    }
}
