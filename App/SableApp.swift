import SwiftUI
import AVFoundation

// OWNER: library agent (app shell).

@main
struct SableApp: App {
    @State private var services: AppServices

    init() {
        SableFonts.registerAll()
        _services = State(initialValue: AppServices.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }
}
