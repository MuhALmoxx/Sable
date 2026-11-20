import XCTest
import TranslationKit
@testable import Sable

/// App-side ChatGPT plan pieces that need no network: settings keys, provider tags (existing
/// providers unchanged), job error messages and the model choice.
final class ChatGPTPlanOptionTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "com.murisixz.sable.tests.chatgpt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    @MainActor
    func testChatGPTSettingsDefaultsAndRoundTrip() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.chatGPTModelID, "", "No model is chosen until the account's models load")
        XCTAssertFalse(settings.chatGPTPlanNoticeShown)
        settings.chatGPTModelID = "model-slug"
        settings.chatGPTPlanNoticeShown = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.chatGPTModelID, "model-slug")
        XCTAssertTrue(reloaded.chatGPTPlanNoticeShown)
    }

    func testProviderTags() {
        let plan = TranslationProviderOption(descriptor: ChatGPTPlanTranslationProvider.descriptor,
                                             unavailableReason: "Sign in with ChatGPT in Settings › Translation",
                                             unavailableTag: "Sign in")
        XCTAssertFalse(plan.isAvailable)
        XCTAssertEqual(plan.displayTags, ["Plus or Pro", "Preview", "Sign in"], "Plan usage is neither free nor paid")
        let signedIn = TranslationProviderOption(descriptor: ChatGPTPlanTranslationProvider.descriptor)
        XCTAssertEqual(signedIn.displayTags, ["Plus or Pro", "Preview"])

        // Existing providers keep their tags.
        let claude = TranslationProviderOption(descriptor: ClaudeTranslationProvider.descriptor, unavailableReason: "Add API key")
        XCTAssertEqual(claude.displayTags, ["Paid", "Add API key"])
        XCTAssertEqual(TranslationProviderOption(descriptor: AppleTranslationProvider.descriptor).displayTags, ["Free", "On-device"])
    }

    func testPlanDescriptorNeedsConfirmationButIsNotPaid() {
        let descriptor = ChatGPTPlanTranslationProvider.descriptor
        XCTAssertEqual(descriptor.id, ChatGPTPlan.providerID)
        XCTAssertTrue(descriptor.usesSubscriptionAllowance)
        XCTAssertFalse(descriptor.isPaid)
        XCTAssertFalse(ClaudeTranslationProvider.descriptor.usesSubscriptionAllowance)
        XCTAssertFalse(AppleTranslationProvider.descriptor.usesSubscriptionAllowance)
    }

    @MainActor
    func testPlanErrorsExplainWhatToDo() {
        let limit = TranslationService.message(for: TranslationError.planUsageLimitReached)
        XCTAssertTrue(limit.contains("usage limit"), limit)
        XCTAssertTrue(limit.contains("Resume"), limit)
        let notEligible = TranslationService.message(for: TranslationError.planNotEligible("subscription_sharing_user_not_eligible"))
        XCTAssertTrue(notEligible.contains("Plus or Pro"), notEligible)
        let signIn = TranslationService.message(for: TranslationError.signInRequired("expired"))
        XCTAssertTrue(signIn.contains("Sign in with ChatGPT"), signIn)
        // Unchanged for the other errors.
        XCTAssertEqual(TranslationService.message(for: TranslationError.invalidAPIKey), TranslationError.invalidAPIKey.errorDescription)
    }

    @MainActor
    func testSignedOutAccountUsesTheChosenModelUntilTheListLoads() {
        let account = ChatGPTAccountService(store: KeychainChatGPTStore(storage: ChatGPTKeychainStoreTests.MemoryStorage()))
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertEqual(account.modelsState, .idle)
        XCTAssertNil(account.effectiveModelID(chosen: ""), "No model without a choice or a list")
        XCTAssertEqual(account.effectiveModelID(chosen: "chosen-slug"), "chosen-slug")
    }

    @MainActor
    func testSavedCredentialStartsSignedIn() throws {
        let storage = ChatGPTKeychainStoreTests.MemoryStorage()
        let store = KeychainChatGPTStore(storage: storage)
        let credential = ChatGPTKeychainStoreTests.makeCredential()
        try store.saveAccount(credential.account)
        try store.saveCredential(credential)
        // A fake transport: the model list request fails without touching the network.
        let account = ChatGPTAccountService(store: store, httpClient: FailingHTTPClient())
        XCTAssertEqual(account.state, .signedIn(email: "reader@example.com"))
        XCTAssertEqual(account.email, "reader@example.com")
    }

    struct FailingHTTPClient: TranslationHTTPClient {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }
}
