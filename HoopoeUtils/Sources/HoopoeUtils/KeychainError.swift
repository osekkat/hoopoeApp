import Foundation

/// Errors that can occur during Keychain operations.
public enum KeychainError: Error, Sendable {
    /// The requested key was not found in the Keychain.
    case itemNotFound

    /// An item with the same service and account already exists.
    case duplicateItem

    /// The Keychain is locked or access has been denied by the system.
    case accessDenied

    /// The provided data could not be encoded or decoded as UTF-8.
    case encodingFailed

    /// An underlying Security framework error occurred.
    case unhandledError(status: Int32)
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            "The requested API key was not found in the Keychain."
        case .duplicateItem:
            "An API key with this service and account already exists."
        case .accessDenied:
            "Keychain access was denied. Check your app's entitlements."
        case .encodingFailed:
            "Failed to encode or decode the API key as UTF-8."
        case .unhandledError(let status):
            "Keychain error (OSStatus \(status))."
        }
    }
}
