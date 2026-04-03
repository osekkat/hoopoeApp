import Foundation
import Observation

/// Holds configured LLM providers and exposes them to the UI.
///
/// The registry is `@Observable` so SwiftUI views can react to provider changes
/// (e.g., a new API key being added). In Phase 2+, this will be replaced by
/// the Rust engine's provider management exposed via UniFFI.
@Observable
@MainActor
public final class ProviderRegistry {
    /// All registered providers, keyed by their `id`.
    public private(set) var providers: [String: any LLMProvider] = [:]

    /// Providers that have valid API keys configured.
    public var configuredProviders: [any LLMProvider] {
        providers.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// All available models across configured providers.
    public var allModels: [(provider: any LLMProvider, model: LLMModel)] {
        configuredProviders.flatMap { provider in
            provider.availableModels.map { (provider: provider, model: $0) }
        }
    }

    public init(providers: [any LLMProvider] = []) {
        replaceProviders(with: providers)
    }

    /// Register a provider when it has configuration available.
    public func register(_ provider: any LLMProvider) {
        guard provider.isConfigured else {
            providers.removeValue(forKey: provider.id)
            return
        }

        providers[provider.id] = provider
    }

    /// Replace the entire configured provider set using a discovery pass.
    public func replaceProviders(with discoveredProviders: [any LLMProvider]) {
        providers.removeAll(keepingCapacity: true)

        for provider in discoveredProviders where provider.isConfigured {
            providers[provider.id] = provider
        }
    }

    /// Remove a provider by its `id`.
    public func unregister(id: String) {
        providers.removeValue(forKey: id)
    }

    /// Look up a provider by `id`.
    public func provider(for id: String) -> (any LLMProvider)? {
        providers[id]
    }
}
