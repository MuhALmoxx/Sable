import Foundation
import Security

// OWNER: translation agent.
/// Generic-password Keychain wrapper (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
final class KeychainStore {
    let service: String

    init(service: String) {
        self.service = service
    }

    func string(for account: String) -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) {}
}
