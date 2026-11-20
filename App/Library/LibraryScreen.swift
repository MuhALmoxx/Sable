import SwiftUI

// OWNER: library agent.
struct LibraryScreen: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            Text("Sable").font(Typo.display).foregroundStyle(Palette.textPrimary)
        }
        .accessibilityIdentifier(AX.Library.screen)
    }
}
