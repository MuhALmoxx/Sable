import SwiftUI
import TranslationKit

// OWNER: translation agent. Embedded by the Settings screen (provider choice, API key, model,
// ChatGPT plan sign-in).
struct TranslationSettingsSection: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let service = services.translation
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SectionLabel("Translation")

            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionLabel("Default provider")
                ForEach(service.providerOptions) { option in
                    TranslationChoiceRow(title: option.descriptor.displayName, detail: option.descriptor.summary,
                                         tags: option.displayTags,
                                         isSelected: services.settings.translationProviderID == option.id,
                                         isEnabled: true,
                                         accessibilityID: AX.Settings.defaultProvider(option.id)) {
                        services.settings.translationProviderID = option.id
                    }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionLabel("Claude API key")
                ClaudeAPIKeyEditor(service: service)
                Text("Claude translation is billed by Anthropic to your own account. Sable never sends anything until you confirm a job, and the confirmation shows the number of lines, requests, estimated tokens and an approximate cost first. Only the subtitle text of the track you translate is sent.")
                    .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionLabel("Claude model")
                ForEach(ClaudeModels.options) { option in
                    TranslationChoiceRow(title: option.displayName, detail: "\(option.note) · \(option.priceLabel)",
                                         isSelected: services.settings.claudeModelID == option.id,
                                         accessibilityID: AX.Settings.claudeModel(option.id)) {
                        services.settings.claudeModelID = option.id
                    }
                }
                Text("Prices are per million tokens (input / output) and are used for the estimate only. Sable never changes the model on its own; if Anthropic declines a request for safety reasons it may answer it with a fallback model, and the job summary says so.")
                    .font(Typo.reading).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ChatGPTPlanSettingsBlock(service: service)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionLabel("Apple on-device")
                Text(service.appleAvailability.label)
                    .font(Typo.body).foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Free and private — nothing leaves your iPhone. It translates one line at a time without the surrounding dialogue, so names, gender and continuity are less consistent than with Claude, and the Translate sheet must stay open while it runs.")
                    .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await service.refreshAppleAvailability() }
    }
}

/// Secure entry for the Claude key: save (Keychain), test (free GET /v1/models), remove.
/// The key is never shown again after saving — only its last four characters.
struct ClaudeAPIKeyEditor: View {
    let service: TranslationService
    var onSaved: (() -> Void)? = nil

    enum Status: Equatable {
        case idle
        case testing
        case valid
        case message(String, isError: Bool)
    }

    @State private var draft = ""
    @State private var status: Status = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if service.hasClaudeKey {
                HStack(spacing: Spacing.xs) {
                    PixelIcon(.key, size: 16, color: Palette.textSecondary)
                    Text(service.claudeKeySuffix.map { "Key saved · ending …\($0)" } ?? "Key saved")
                        .font(Typo.body).foregroundStyle(Palette.textPrimary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AX.Settings.apiKeyStatus)
            }
            SecureField(service.hasClaudeKey ? "Replace key (sk-ant-…)" : "Paste API key (sk-ant-…)", text: $draft)
                .font(Typo.mono)
                .foregroundStyle(Palette.textPrimary)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { save() }
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: Spacing.touch)
                .pixelPanel(fill: Palette.surface)
                .accessibilityLabel("Claude API key")
                .accessibilityIdentifier(AX.Settings.apiKeyField)
            HStack(spacing: Spacing.sm) {
                Button("Save") { save() }
                    .buttonStyle(PixelButtonStyle(kind: draft.isEmpty ? .secondary : .primary, compact: true))
                    .frame(minHeight: Spacing.touch)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Save API key")
                    .accessibilityIdentifier(AX.Settings.apiKeySave)
                Button("Test") { test() }
                    .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
                    .frame(minHeight: Spacing.touch)
                    .disabled(!service.hasClaudeKey || status == .testing)
                    .accessibilityLabel("Test API key")
                    .accessibilityIdentifier(AX.Settings.apiKeyTest)
                Spacer(minLength: 0)
                if service.hasClaudeKey {
                    Button("Remove") { remove() }
                        .buttonStyle(PixelButtonStyle(kind: .destructive, compact: true))
                        .frame(minHeight: Spacing.touch)
                        .accessibilityLabel("Remove API key")
                        .accessibilityIdentifier(AX.Settings.apiKeyRemove)
                }
            }
            statusView
        }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            Text("Checking the key with Anthropic (free)…").font(Typo.reading).foregroundStyle(Palette.textSecondary)
        case .valid:
            Text("The key works.").font(Typo.reading).foregroundStyle(Palette.success)
        case let .message(text, isError):
            Text(text).font(Typo.reading).foregroundStyle(isError ? Palette.danger : Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try service.saveClaudeKey(key)
            draft = ""
            onSaved?()
            test()
        } catch {
            status = .message(error.localizedDescription, isError: true)
        }
    }

    private func test() {
        status = .testing
        Task {
            do {
                try await service.validateClaudeKey()
                status = .valid
            } catch {
                status = .message((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
            }
        }
    }

    private func remove() {
        service.removeClaudeKey()
        draft = ""
        status = .message("Key removed from this iPhone.", isError: false)
    }
}
