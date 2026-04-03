import Foundation
import Security

// MARK: - Stored Credential

/// A credential retrieved from the Keychain.
public struct StoredCredential: Sendable {
    /// The service identifier (e.g., "com.hoopoe.api-key.anthropic").
    public let service: String

    /// The account identifier (e.g., "default" or a rotation label).
    public let account: String

    /// The secret value (API key).
    public let secret: String
}

// MARK: - KeychainService

/// Thread-safe wrapper around macOS Security framework Keychain operations.
///
/// Designed for future UniFFI bridgeability: all public methods are simple async functions
/// returning plain types with no closures or generics.
///
/// Service names follow the pattern `com.hoopoe.api-key.<provider>` to avoid collisions
/// with other apps.
public actor KeychainService {

    /// The bundle-scoped prefix for all Keychain service entries.
    private static let servicePrefix = "com.hoopoe.api-key."

    /// Known provider identifiers for format validation.
    public enum Provider: String, Sendable, CaseIterable {
        case anthropic
        case openai
        case google
    }

    public init() {}

    // MARK: - CRUD

    /// Store an API key for a provider and account.
    ///
    /// - Parameters:
    ///   - secret: The API key value.
    ///   - provider: The provider identifier (e.g., "anthropic").
    ///   - account: An account label (defaults to "default").
    /// - Throws: `KeychainError.duplicateItem` if an entry already exists.
    public func store(secret: String, provider: String, account: String = "default") throws {
        guard let secretData = secret.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let service = Self.serviceName(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secretData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw KeychainError.duplicateItem
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Retrieve an API key for a provider and account.
    ///
    /// - Parameters:
    ///   - provider: The provider identifier.
    ///   - account: The account label (defaults to "default").
    /// - Returns: The stored secret string.
    /// - Throws: `KeychainError.itemNotFound` if no matching entry exists.
    public func retrieve(provider: String, account: String = "default") throws -> String {
        let service = Self.serviceName(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let secret = String(data: data, encoding: .utf8) else {
                throw KeychainError.encodingFailed
            }
            return secret
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Update an existing API key, or store it if none exists.
    ///
    /// - Parameters:
    ///   - secret: The new API key value.
    ///   - provider: The provider identifier.
    ///   - account: The account label (defaults to "default").
    public func upsert(secret: String, provider: String, account: String = "default") throws {
        guard let secretData = secret.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let service = Self.serviceName(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: secretData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try store(secret: secret, provider: provider, account: account)
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Delete an API key from the Keychain.
    ///
    /// - Parameters:
    ///   - provider: The provider identifier.
    ///   - account: The account label (defaults to "default").
    /// - Throws: `KeychainError.itemNotFound` if no matching entry exists.
    public func delete(provider: String, account: String = "default") throws {
        let service = Self.serviceName(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// List all stored credentials for a provider.
    ///
    /// - Parameter provider: The provider identifier.
    /// - Returns: An array of `StoredCredential` entries (secrets omitted — use `retrieve` for values).
    public func listAccounts(provider: String) throws -> [StoredCredential] {
        let service = Self.serviceName(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                return []
            }
            return items.compactMap { item in
                guard let account = item[kSecAttrAccount as String] as? String else {
                    return nil
                }
                return StoredCredential(service: service, account: account, secret: "")
            }
        case errSecItemNotFound:
            return []
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// List all stored provider credentials across all known providers.
    ///
    /// - Returns: An array of `StoredCredential` entries grouped by provider.
    public func listAllProviders() throws -> [StoredCredential] {
        var all: [StoredCredential] = []
        for provider in Provider.allCases {
            let accounts = try listAccounts(provider: provider.rawValue)
            all.append(contentsOf: accounts)
        }
        return all
    }

    // MARK: - Format Validation

    /// Validate the format of an API key for a given provider.
    ///
    /// This performs local format checks only — it does NOT call any external API.
    ///
    /// - Parameters:
    ///   - key: The API key string to validate.
    ///   - provider: The provider identifier.
    /// - Returns: `true` if the key matches the expected format.
    public func validateKeyFormat(key: String, provider: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        switch provider {
        case Provider.anthropic.rawValue:
            // Anthropic keys start with "sk-ant-" and are 90+ characters
            return trimmed.hasPrefix("sk-ant-") && trimmed.count >= 90
        case Provider.openai.rawValue:
            // OpenAI keys start with "sk-" and are 40+ characters
            return trimmed.hasPrefix("sk-") && trimmed.count >= 40
        case Provider.google.rawValue:
            // Google API keys are typically 39 characters, alphanumeric + dashes
            return trimmed.count >= 30
        default:
            // Unknown provider — accept any non-empty key
            return true
        }
    }

    // MARK: - Internal

    /// Build a fully-qualified service name for Keychain entries.
    private static func serviceName(for provider: String) -> String {
        "\(servicePrefix)\(provider)"
    }
}
