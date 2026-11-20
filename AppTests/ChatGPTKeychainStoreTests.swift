import Security
import XCTest
import TranslationKit
@testable import Sable

/// KeychainChatGPTStore: JSON records under their own Keychain accounts, the ext_agent_host_id
/// created once per installation, and sign-out keeping the account/client mapping.
final class ChatGPTKeychainStoreTests: XCTestCase {
    /// Thread-safe in-memory stand-in for the Keychain (always available, unlike the Keychain in
    /// an unsigned simulator build).
    final class MemoryStorage: ChatGPTSecureStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]

        func data(for account: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return items[account]
        }

        func setData(_ value: Data, for account: String) throws {
            lock.lock(); defer { lock.unlock() }
            items[account] = value
        }

        func remove(_ account: String) {
            lock.lock(); defer { lock.unlock() }
            items[account] = nil
        }

        var accounts: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return Set(items.keys)
        }
    }

    static func makeCredential(hostID: String = "urn:uuid:00000000-0000-4000-8000-000000000001") -> ChatGPTCredential {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return ChatGPTCredential(account: ChatGPTAccount(clientID: "oaiapp_test", email: "reader@example.com", subject: "user-123"),
                                 issuer: "https://auth.openai.com", hostID: hostID, idToken: "id-token",
                                 accessToken: "access-token", refreshToken: "refresh-token", tokenType: "Bearer",
                                 scopes: ["openid", "offline_access"], accessTokenExpiresAt: now.addingTimeInterval(3600),
                                 earliestRefreshAt: now.addingTimeInterval(1800), savedAt: now)
    }

    func testCredentialAndAccountRoundTripAndSignOutKeepsTheAccount() throws {
        let storage = MemoryStorage()
        let store = KeychainChatGPTStore(storage: storage)
        XCTAssertNil(store.loadCredential())
        XCTAssertNil(store.loadAccount())

        let credential = Self.makeCredential()
        try store.saveAccount(credential.account)
        try store.saveCredential(credential)
        XCTAssertEqual(store.loadCredential(), credential)
        XCTAssertEqual(store.loadAccount(), credential.account)
        XCTAssertEqual(storage.accounts, [KeychainChatGPTStore.credentialAccount, KeychainChatGPTStore.accountAccount])

        // A second store over the same storage (next launch) sees the same records.
        let reopened = KeychainChatGPTStore(storage: storage)
        XCTAssertEqual(reopened.loadCredential(), credential)

        reopened.deleteCredential()
        XCTAssertNil(reopened.loadCredential(), "Sign-out deletes the tokens")
        XCTAssertEqual(reopened.loadAccount(), credential.account, "Sign-out keeps the account/client mapping")
    }

    func testHostIDIsCreatedOnceAndPersisted() throws {
        let storage = MemoryStorage()
        let store = KeychainChatGPTStore(storage: storage)
        XCTAssertNil(store.storedHostID())
        let first = try store.hostID()
        XCTAssertTrue(first.hasPrefix("urn:uuid:"), first)
        XCTAssertNotNil(UUID(uuidString: String(first.dropFirst("urn:uuid:".count))), "\(first) must carry a UUID")
        XCTAssertEqual(first, first.lowercased())
        XCTAssertEqual(try store.hostID(), first, "The host id is chosen once")
        XCTAssertEqual(try KeychainChatGPTStore(storage: storage).hostID(), first, "…and survives a relaunch")

        try store.saveCredential(Self.makeCredential())
        store.deleteCredential()
        XCTAssertEqual(try store.hostID(), first, "…and a sign-out")
    }

    func testHostIDAdoptsTheOneASavedCredentialWasIssuedFor() throws {
        let storage = MemoryStorage()
        let store = KeychainChatGPTStore(storage: storage)
        let issuedFor = "urn:uuid:11111111-2222-4333-8444-555555555555"
        try store.saveCredential(Self.makeCredential(hostID: issuedFor))
        XCTAssertEqual(try store.hostID(), issuedFor)
        XCTAssertEqual(store.storedHostID(), issuedFor)
    }

    func testCorruptRecordReadsAsMissing() throws {
        let storage = MemoryStorage()
        try storage.setData(Data("not json".utf8), for: KeychainChatGPTStore.credentialAccount)
        XCTAssertNil(KeychainChatGPTStore(storage: storage).loadCredential())
    }

    /// The real Keychain, under a throwaway service so the app's own items are untouched.
    func testRoundTripThroughTheKeychain() throws {
        let keychain = KeychainStore(service: "com.murisixz.sable.tests.chatgpt.\(UUID().uuidString)")
        addTeardownBlock {
            for account in [KeychainChatGPTStore.credentialAccount, KeychainChatGPTStore.accountAccount,
                            KeychainChatGPTStore.hostIDAccount, "plain-string"] {
                keychain.remove(account)
            }
        }
        let store = KeychainChatGPTStore(storage: keychain)
        let credential = Self.makeCredential()
        do {
            try store.saveCredential(credential)
        } catch let KeychainStore.KeychainError.unexpectedStatus(status)
                    where status == errSecMissingEntitlement || status == errSecNotAvailable {
            throw XCTSkip("The Keychain is unavailable to this unsigned simulator build (status \(status)); the in-memory tests cover the store logic")
        }
        try store.saveAccount(credential.account)
        XCTAssertEqual(store.loadCredential(), credential)
        XCTAssertEqual(store.loadAccount(), credential.account)
        let hostID = try store.hostID()
        XCTAssertEqual(KeychainChatGPTStore(storage: keychain).storedHostID(), hostID)

        // Update-in-place (rotated tokens) keeps one record.
        var rotated = credential
        rotated.accessToken = "access-token-2"
        rotated.refreshToken = "refresh-token-2"
        try store.saveCredential(rotated)
        XCTAssertEqual(store.loadCredential(), rotated)

        store.deleteCredential()
        XCTAssertNil(store.loadCredential())
        XCTAssertEqual(store.loadAccount(), credential.account)
        XCTAssertEqual(store.storedHostID(), hostID)

        // The string API used for the Claude key still works on the same wrapper.
        try keychain.set("sk-ant-test", for: "plain-string")
        XCTAssertEqual(keychain.string(for: "plain-string"), "sk-ant-test")
    }
}
