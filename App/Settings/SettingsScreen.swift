import SwiftUI

// OWNER: library agent (settings + about/licenses).
struct SettingsScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                TranslationSettingsSection()
            }
            .padding(Spacing.md)
        }
        .background(Palette.background.ignoresSafeArea())
        .accessibilityIdentifier(AX.Settings.screen)
    }
}
