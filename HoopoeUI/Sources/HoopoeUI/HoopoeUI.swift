import SwiftUI

/// Root namespace for Hoopoe UI components.
///
/// Future phases will add views for Planning, Beads, Swarm, Hardening, and Learning.
public enum HoopoeUIModule {
    public static let version = "0.1.0"
}

// LLM types are defined in the LLM/ subdirectory and auto-exported
// as part of the HoopoeUI module:
//   - LLMProvider (protocol)
//   - LLMModel
//   - LLMEvent, LLMResponse, TokenUsage
//   - LLMError
//   - ProviderRegistry
