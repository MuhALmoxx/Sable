import SwiftUI

// OWNER: translation agent. Presented from the player.
struct TranslationSheet: View {
    let session: PlayerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PixelSheet(title: "Translate", onClose: { dismiss() }) {
            Spacer()
        }
        .accessibilityIdentifier(AX.Translation.sheet)
    }
}
