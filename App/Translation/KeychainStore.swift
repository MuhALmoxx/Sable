import Foundation
import Security

// OWNER: translation agent.
/// Generic-password Keychain wrapper (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
/// Values never leave the device (no iCloud Keychain sync) and are never logged.
final class KeychainStore {
    let service: String

    init(service: String) {
        self.service = service
    }

    enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                var message = "status \(status)"
                if let cfMessage = SecCopyErrorMessageString(status, nil) { message = cfMessage as String }
                return "The Keychain could not store the value (\(message))."
            }
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Update-or-add.
    func set(_ value: String, for account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account)
            for (key, value) in attributes { add[key] = value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
