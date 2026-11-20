import Foundation
import TranslationKit

// OWNER: ChatGPT app layer (translation). Keychain storage for "Sign in with ChatGPT".
//
// Three generic-password items under the app's Keychain service (the same service as the Claude
// key, so the `-uiTesting` reset in UITestSupport wipes them too), each
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (never synced or restored to another device):
//   chatgpt-plan-credential  JSON ChatGPTCredential (tokens + identity); deleted on sign-out
//   chatgpt-plan-account     JSON ChatGPTAccount (issued client id + identity); kept on sign-out
//   chatgpt-plan-host-id     ext_agent_host_id ("urn:uuid:…"), created once per installation
// Nothing here is ever logged.

/// Byte storage behind `KeychainChatGPTStore`: the Keychain in the app, memory in unit tests.
protocol ChatGPTSecureStorage: Sendable {
    func data(for account: String) -> Data?
    func setData(_ value: Data, for account: String) throws
    func remove(_ account: String)
}

extension KeychainStore: ChatGPTSecureStorage {}

struct KeychainChatGPTStore: ChatGPTCredentialStore {
    static let credentialAccount = "chatgpt-plan-credential"
    static let accountAccount = "chatgpt-plan-account"
    static let hostIDAccount = "chatgpt-plan-host-id"

    let storage: any ChatGPTSecureStorage

    init(storage: any ChatGPTSecureStorage) {
        self.storage = storage
    }

    // MARK: ChatGPTCredentialStore

    func loadCredential() -> ChatGPTCredential? {
        decode(ChatGPTCredential.self, account: Self.credentialAccount)
    }

    func saveCredential(_ credential: ChatGPTCredential) throws {
        try encode(credential, account: Self.credentialAccount)
    }

    func deleteCredential() {
        storage.remove(Self.credentialAccount)
    }

    func loadAccount() -> ChatGPTAccount? {
        decode(ChatGPTAccount.self, account: Self.accountAccount)
    }

    func saveAccount(_ account: ChatGPTAccount) throws {
        try encode(account, account: Self.accountAccount)
    }

    // MARK: Host id

    /// The saved ext_agent_host_id, if one was created.
    func storedHostID() -> String? {
        guard let data = storage.data(for: Self.hostIDAccount),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// This installation's ext_agent_host_id: the saved one, else the one a saved credential was
    /// issued for, else a new "urn:uuid:<UUIDv4>". Persisted before it is returned, so it is chosen
    /// once, before the first sign-in, and stays the same across sign-outs.
    func hostID() throws -> String {
        if let existing = storedHostID() { return existing }
        let adopted = loadCredential()?.hostID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = adopted.isEmpty ? ChatGPTPlan.newHostID() : adopted
        try storage.setData(Data(id.utf8), for: Self.hostIDAccount)
        return id
    }

    // MARK: JSON

    private func decode<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = storage.data(for: account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        try storage.setData(data, for: account)
    }
}
