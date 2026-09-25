import Foundation
import Security

enum APIKeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case emptyKey

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "钥匙串操作失败（代码 \(status)）。"
        case .emptyKey: "请输入 API 密钥。"
        }
    }
}

enum APIKeyStore {
    private static func service(for provider: AIProvider) -> String {
        "com.kda.spanishlearningmac.\(provider.rawValue)"
    }
    private static let account = "personal-api-key"

    static func read(for provider: AIProvider = .openAI) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIKeyStoreError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func save(_ key: String, for provider: AIProvider = .openAI) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIKeyStoreError.emptyKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service(for: provider),
                                    kSecAttrAccount as String: account]
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insert = SecItemAdd(item as CFDictionary, nil)
            guard insert == errSecSuccess else { throw APIKeyStoreError.keychain(insert) }
        } else if status != errSecSuccess {
            throw APIKeyStoreError.keychain(status)
        }
    }

    static func delete(for provider: AIProvider = .openAI) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service(for: provider),
                                    kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeyStoreError.keychain(status) }
    }
}
