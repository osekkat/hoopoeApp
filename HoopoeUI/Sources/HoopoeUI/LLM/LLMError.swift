import Foundation

/// Errors that can occur during LLM API communication.
public enum LLMError: Error, Equatable, Sendable {
    /// API key is missing or invalid.
    case authenticationFailed

    /// Rate limit hit. Retry after the specified number of seconds, if known.
    case rateLimited(retryAfter: TimeInterval?)

    /// The prompt exceeds the model's context window.
    case contextTooLong

    /// Network connectivity issue.
    case networkError(message: String)

    /// Server returned an error response.
    case serverError(message: String)
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "Authentication failed. Check your API key."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Rate limited. Retry after \(retryAfter) seconds."
            } else {
                "Rate limited. Please try again later."
            }
        case .contextTooLong:
            "The prompt exceeds the model's context window."
        case .networkError(let message):
            "Network error: \(message)"
        case .serverError(let message):
            "Server error: \(message)"
        }
    }
}
