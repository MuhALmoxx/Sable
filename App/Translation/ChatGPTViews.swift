import SwiftUI
import TranslationKit

// OWNER: ChatGPT app layer (translation). "Sign in with ChatGPT" UI pieces shared by Settings ›
// Translation and the Translate sheet.
//
// Branding: OpenAI asks apps to use its approved branding and assets. Sable bundles none, so the
// button is the plain text label "Sign in with ChatGPT" in Sable's own pixel button style; no
// ChatGPT or OpenAI logo is drawn or imitated anywhere.

/// Settings › Translation › ChatGPT plan: explanation + sign-in, or account, model and sign-out.
struct ChatGPTPlanSettingsBlock: View {
    let service: TranslationService

    private var account: ChatGPTAccountService { service.chatGPT }

    static let disclosure = "Use your ChatGPT Plus or Pro plan instead of an API key. Translations count toward your ChatGPT usage limits (on Plus, the 5-hour limit is shared with other apps). This is not OpenAI API access; Sable never sees your password."

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                SectionLabel("ChatGPT plan")
                PixelTag("OpenAI preview")
                    .accessibilityLabel("OpenAI preview feature")
                    .accessibilityIdentifier(AX.ChatGPT.previewTag)
            }
            switch account.state {
            case .signedOut:
                signedOutContent(error: nil)
            case let .failed(message):
                signedOutContent(error: message)
            case .signingIn:
                signingInContent
            case let .signedIn(email):
                signedInContent(email: email)
            case .signingOut:
                progressRow("Signing out…")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.ChatGPT.block)
    }

    // MARK: Signed out

    private func signedOutContent(error: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(Self.disclosure)
                .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AX.ChatGPT.disclosure)
            Text("Sable is free. Using your ChatGPT plan here needs an eligible ChatGPT Plus or Pro plan.")
                .font(Typo.reading).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .font(Typo.reading).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.ChatGPT.error)
            }
            Button { account.signIn() } label: {
                Text("Sign in with ChatGPT").frame(maxWidth: .infinity)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .accessibilityLabel("Sign in with ChatGPT")
            .accessibilityHint("Opens OpenAI's sign-in page in a browser sheet.")
            .accessibilityIdentifier(AX.ChatGPT.signIn)
        }
    }

    private var signingInContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            progressRow("Finish signing in on the OpenAI page…")
            Button("Cancel") { account.cancelSignIn() }
                .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
                .frame(minHeight: Spacing.touch)
                .accessibilityLabel("Cancel ChatGPT sign-in")
                .accessibilityIdentifier(AX.ChatGPT.cancelSignIn)
        }
    }

    // MARK: Signed in

    private func signedInContent(email: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(email.map { "Signed in as \($0)" } ?? "Signed in with ChatGPT")
                .font(Typo.body).foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AX.ChatGPT.status)
            modelContent
            ChatGPTUsageIndicator()
            Text("Translations with this provider count toward your ChatGPT plan's usage limits. Sable charges nothing, and this is not OpenAI API access.")
                .font(Typo.reading).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign out") { Task { await service.signOutOfChatGPT() } }
                .buttonStyle(PixelButtonStyle(kind: .destructive, compact: true))
                .frame(minHeight: Spacing.touch)
                .accessibilityLabel("Sign out of ChatGPT")
                .accessibilityIdentifier(AX.ChatGPT.signOut)
        }
    }

    @ViewBuilder private var modelContent: some View {
        switch account.modelsState {
        case .idle, .loading:
            progressRow("Loading the models of your plan…")
        case let .failed(message):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Couldn't load your ChatGPT models. \(message)")
                    .font(Typo.reading).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.ChatGPT.error)
                Button("Try again") { account.loadModels() }
                    .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
                    .frame(minHeight: Spacing.touch)
                    .accessibilityLabel("Load ChatGPT models again")
                    .accessibilityIdentifier(AX.ChatGPT.modelsRetry)
            }
        case .loaded:
            if account.models.isEmpty {
                Text("No ChatGPT model is available to this account.")
                    .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ChatGPTModelMenu(models: account.models, selectedID: service.chatGPTModelID,
                                 selectedName: service.chatGPTModelName) { slug in
                    service.settings.chatGPTModelID = slug
                }
            }
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            PixelSpinner(size: 16, label: text)
            Text(text).font(Typo.reading).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: Spacing.touch)
        .accessibilityElement(children: .combine)
    }
}

/// Model picker for the ChatGPT plan: shows `display_name`, stores the slug.
struct ChatGPTModelMenu: View {
    let models: [ChatGPTModel]
    let selectedID: String?
    let selectedName: String
    var isEnabled: Bool = true
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(models) { option in
                Button(option.slug == selectedID ? "\(option.displayName) (selected)" : option.displayName) {
                    onSelect(option.slug)
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(Typo.micro).foregroundStyle(Palette.textTertiary)
                    Text(selectedName.isEmpty ? "Choose a model" : selectedName)
                        .font(Typo.callout).foregroundStyle(Palette.textPrimary)
                }
                Spacer(minLength: 0)
                PixelIcon(.chevronDown, size: 14, color: Palette.textSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Spacing.touch, alignment: .leading)
            .pixelPanel()
            .contentShape(Rectangle())
        }
        .disabled(!isEnabled || models.isEmpty)
        .accessibilityLabel("ChatGPT model: \(selectedName.isEmpty ? "none chosen" : selectedName)")
        .accessibilityIdentifier(AX.ChatGPT.modelPicker)
    }
}

/// "Using ChatGPT plan" + "Manage usage" (opens chatgpt.com/settings/usage).
struct ChatGPTUsageIndicator: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                label
                Spacer(minLength: Spacing.xs)
                manageButton
            }
            VStack(alignment: .leading, spacing: 0) {
                label
                manageButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: Spacing.xs) {
            PixelIcon(.info, size: 14, color: Palette.textSecondary)
                .accessibilityHidden(true)
            Text("Using ChatGPT plan").font(Typo.callout).foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.ChatGPT.usageIndicator)
    }

    private var manageButton: some View {
        Button { openURL(ChatGPTPlan.manageUsageURL) } label: {
            Label { Text("Manage usage") } icon: { PixelIcon(.export, size: 14) }
        }
        .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
        .accessibilityLabel("Manage usage")
        .accessibilityHint("Opens your ChatGPT usage settings in the browser.")
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier(AX.ChatGPT.manageUsage)
    }
}

/// One-time notice when the ChatGPT plan provider is first used (shown over the Translate sheet).
struct ChatGPTPlanNotice: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Palette.scrimStrong
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You're using your ChatGPT plan")
                    .font(Typo.headline).foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Eligible usage in this app uses your ChatGPT plan. Manage usage in your ChatGPT settings.")
                    .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { onDismiss() } label: {
                    Text("Got it").frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityIdentifier(AX.ChatGPT.noticeDismiss)
            }
            .padding(Spacing.md)
            .frame(maxWidth: 420)
            .pixelPanel(fill: Palette.surfaceRaised, border: Palette.borderStrong)
            .padding(.horizontal, Spacing.lg)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier(AX.ChatGPT.notice)
        }
    }
}
