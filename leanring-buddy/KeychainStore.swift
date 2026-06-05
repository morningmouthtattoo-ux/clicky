//
//  KeychainStore.swift
//  leanring-buddy
//
//  A tiny wrapper around the macOS Keychain for storing the user's Anthropic
//  (Claude) API key on-device. This is the same secure vault Safari uses for
//  passwords — the key is encrypted at rest and never lives in plain text in
//  the app bundle, UserDefaults, or source control.
//
//  Why this exists: this fork talks to Claude directly instead of through a
//  Cloudflare Worker, so the key has to live somewhere on the user's Mac.
//  The Keychain is the right home for it.
//

import Foundation
import Security

enum KeychainStore {
    /// Namespacing the items under the app's bundle id keeps them isolated
    /// from any other app's Keychain entries.
    private static let serviceName = "com.morningmouthtattoo.clicky"

    /// The Keychain account under which the Anthropic API key is stored.
    static let anthropicAPIKeyAccount = "anthropic-api-key"

    /// Saves (or overwrites) a string value for the given account.
    /// Returns true on success.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard let valueData = value.data(using: .utf8) else { return false }

        // Remove any existing item first so we don't hit a duplicate error.
        delete(account: account)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: valueData,
            // Available after first unlock, on this device only — never synced
            // to iCloud Keychain and never leaves this Mac.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Reads the string value for the given account, or nil if none is stored.
    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var retrievedItem: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &retrievedItem)

        guard status == errSecSuccess,
              let valueData = retrievedItem as? Data,
              let value = String(data: valueData, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Removes the stored value for the given account (no-op if absent).
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Convenience for the Anthropic key

    /// The stored Anthropic API key, or nil if the user hasn't entered one yet.
    static var anthropicAPIKey: String? {
        read(account: anthropicAPIKeyAccount)
    }

    /// Whether a non-empty Anthropic key is currently stored.
    static var hasAnthropicAPIKey: Bool {
        guard let key = anthropicAPIKey else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saves the Anthropic key (trimming stray whitespace first).
    @discardableResult
    static func saveAnthropicAPIKey(_ key: String) -> Bool {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return save(trimmedKey, account: anthropicAPIKeyAccount)
    }
}
