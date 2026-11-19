#if canImport(Security)
import Foundation
import Security
import Support

/// Generic passwords in the login Keychain, service `YTA`, account = the key name.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "YTA") {
        self.service = service
    }

    private func query(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    public func read(_ key: SecretKey) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw YTAError(.notFound, "The Keychain refused to read the \(key.title) key (\(status)).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func save(_ value: String, for key: SecretKey) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw YTAError(.notFound, "The Keychain refused to save the \(key.title) key (\(status)).")
        }
        Redactor.shared.register(value)
    }

    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw YTAError(.notFound, "The Keychain refused to delete the \(key.title) key (\(status)).")
        }
    }
}
#endif
