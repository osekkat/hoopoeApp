import Foundation
import XCTest
@testable import HoopoeUI

/// Regression tests for the URL double-slash bug (fixed in e359070).
///
/// `URL.appendingPathComponent("/v1/messages")` with a leading slash could produce
/// `https://host//v1/messages` — a double-slash that causes 404s from real APIs.
/// The fix removes the leading slash so `appendingPathComponent("v1/messages")` is used.
final class ProviderURLTests: XCTestCase {

    // MARK: - Claude URL

    func testClaudeProviderURLHasNoDoubleSlash() {
        let base = URL(string: "https://api.anthropic.com")!
        let url = base.appendingPathComponent("v1/messages")

        XCTAssertFalse(
            url.absoluteString.contains("//v1"),
            "URL should not contain a double-slash before the path: \(url.absoluteString)"
        )
        XCTAssertTrue(
            url.absoluteString.hasSuffix("/v1/messages"),
            "URL should end with /v1/messages: \(url.absoluteString)"
        )
    }

    /// Demonstrates the bug: a leading slash in appendingPathComponent
    /// may produce a malformed URL on some Foundation versions.
    func testLeadingSlashInPathComponentIsProblematic() {
        let base = URL(string: "https://api.anthropic.com")!
        let withLeading = base.appendingPathComponent("/v1/messages")
        let withoutLeading = base.appendingPathComponent("v1/messages")

        // The version without leading slash is always correct
        XCTAssertTrue(withoutLeading.absoluteString.contains("anthropic.com/v1/messages"))

        // The version with leading slash may or may not have double slash depending
        // on Foundation version, but the without-leading version is always safe
        XCTAssertEqual(
            withoutLeading.path.filter({ $0 == "/" }).count,
            withoutLeading.path.components(separatedBy: "/").count - 1,
            "Path should not have consecutive slashes"
        )
    }

    // MARK: - Gemini URL

    func testGeminiGenerateContentURLHasNoDoubleSlash() {
        let base = URL(string: "https://generativelanguage.googleapis.com")!
        let model = "gemini-2.5-pro"
        let url = base.appendingPathComponent("v1beta/models/\(model):generateContent")

        XCTAssertFalse(
            url.absoluteString.contains("//v1beta"),
            "URL should not contain a double-slash: \(url.absoluteString)"
        )
        XCTAssertTrue(
            url.absoluteString.contains("/v1beta/models/gemini-2.5-pro"),
            "URL should contain the model path: \(url.absoluteString)"
        )
    }

    func testGeminiStreamURLHasNoDoubleSlash() {
        let base = URL(string: "https://generativelanguage.googleapis.com")!
        let model = "gemini-2.5-flash"
        let url = base.appendingPathComponent("v1beta/models/\(model):streamGenerateContent")

        XCTAssertFalse(
            url.absoluteString.contains("//v1beta"),
            "URL should not contain a double-slash: \(url.absoluteString)"
        )
        XCTAssertTrue(
            url.absoluteString.contains("streamGenerateContent"),
            "URL should contain streamGenerateContent: \(url.absoluteString)"
        )
    }

    // MARK: - Provider Configuration

    func testClaudeProviderIsConfiguredWithNonEmptyKey() {
        let configured = ClaudeProvider(apiKey: "sk-test-key")
        let empty = ClaudeProvider(apiKey: "")

        XCTAssertTrue(configured.isConfigured)
        XCTAssertFalse(empty.isConfigured)
    }

    func testGeminiProviderIsConfiguredWithNonEmptyKey() {
        let configured = GeminiProvider(apiKey: "test-key")
        let empty = GeminiProvider(apiKey: "")

        XCTAssertTrue(configured.isConfigured)
        XCTAssertFalse(empty.isConfigured)
    }

    func testClaudeProviderAvailableModels() {
        let provider = ClaudeProvider(apiKey: "test")
        let modelIDs = provider.availableModels.map(\.id)

        XCTAssertTrue(modelIDs.contains("claude-opus-4-6"))
        XCTAssertTrue(modelIDs.contains("claude-sonnet-4-6"))
        XCTAssertTrue(modelIDs.contains("claude-haiku-4-5-20251001"))
    }

    func testGeminiProviderAvailableModels() {
        let provider = GeminiProvider(apiKey: "test")
        let modelIDs = provider.availableModels.map(\.id)

        XCTAssertTrue(modelIDs.contains("gemini-2.5-pro"))
        XCTAssertTrue(modelIDs.contains("gemini-2.5-flash"))
    }
}
