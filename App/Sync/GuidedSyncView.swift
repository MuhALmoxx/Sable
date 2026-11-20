import SwiftUI

// OWNER: sync agent. Guided "match a spoken line" synchronisation, presented from the player.
struct GuidedSyncView: View {
    let session: PlayerSession
    var onClose: () -> Void = {}

    var body: some View {
        Text("Sync subtitles").font(Typo.headline)
            .accessibilityIdentifier(AX.Sync.flow)
    }
}
