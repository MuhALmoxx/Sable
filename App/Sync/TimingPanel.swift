import SwiftUI

// OWNER: sync agent. Manual offset panel, presented from the player (compact, non-blocking).
struct TimingPanel: View {
    let session: PlayerSession
    var onClose: () -> Void = {}

    var body: some View {
        Text("Timing").font(Typo.headline)
            .accessibilityIdentifier(AX.Timing.panel)
    }
}
