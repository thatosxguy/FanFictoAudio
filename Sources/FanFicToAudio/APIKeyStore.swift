import Foundation
import Security
import LocalAuthentication
import AudiobookCore

enum APIKeyStore {
    private static func query(_ provider: NarrationProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.matt.fanfictoaudio.tts",
         kSecAttrAccount as String: provider.rawValue]
    }
    static func contains(_ provider: NarrationProvider) -> Bool {
        var query = query(provider)
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func read(_ provider: NarrationProvider) throws -> String {
        var query = query(provider)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AudiobookError.conversion("Save your \(provider.rawValue) API key in the narration settings first.")
        }
        return key
    }
    static func save(_ key: String, provider: NarrationProvider) throws {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { throw AudiobookError.conversion("Enter an API key before saving.") }
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    static func remove(_ provider: NarrationProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw AudiobookError.conversion("Keychain could not complete the action (\(status)).") }
    }
}
