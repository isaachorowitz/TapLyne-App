import Foundation
import Security

/// Stores Taplyne's API key in the login keychain.
enum Keychain {
    private static let service = "agency.ziplyne.taplyne"

    enum Account {
        /// The user's primary OpenAI key. It powers direct reasoning and is also
        /// the voice fallback so a normal setup requires only one key.
        static let openAI = "openai-api-key"
        /// Optional. When present, voice uses this key instead of the primary key.
        static let openAIVoiceOverride = "openai-voice-api-key"
        #if DEBUG
        /// Isolated preview/test credential. Production settings never use it.
        static let openAIPreview = "openai-preview-api-key"
        #endif
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    static func contains(_ account: String) -> Bool {
        guard let value = read(account) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func openAIKey() -> String? {
        read(Account.openAI)?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty
    }

    static func voiceOpenAIKey() -> String? {
        read(Account.openAIVoiceOverride)?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty
            ?? openAIKey()
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
