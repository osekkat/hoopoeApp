import Testing
@testable import Hoopoe
@testable import HoopoeUI

@Suite("GenerationFlowState")
@MainActor
struct GenerationFlowStateTests {

    @Test func initialPhaseIsInput() {
        let state = GenerationFlowState()
        #expect(state.isInputPhase)
        #expect(!state.isGenerating)
        #expect(state.completedText == nil)
    }

    @Test func isInputPhaseMatchesInputOnly() {
        let state = GenerationFlowState()

        state.phase = .input
        #expect(state.isInputPhase)

        state.phase = .generating
        #expect(!state.isInputPhase)

        state.phase = .complete(text: "done")
        #expect(!state.isInputPhase)

        state.phase = .failed("error")
        #expect(!state.isInputPhase)
    }

    @Test func isGeneratingMatchesGeneratingOnly() {
        let state = GenerationFlowState()

        state.phase = .generating
        #expect(state.isGenerating)

        state.phase = .input
        #expect(!state.isGenerating)

        state.phase = .complete(text: "x")
        #expect(!state.isGenerating)

        state.phase = .failed("err")
        #expect(!state.isGenerating)
    }

    @Test func completedTextExtractsFromCompletePhase() {
        let state = GenerationFlowState()

        state.phase = .complete(text: "the plan")
        #expect(state.completedText == "the plan")

        state.phase = .input
        #expect(state.completedText == nil)

        state.phase = .generating
        #expect(state.completedText == nil)

        state.phase = .failed("oops")
        #expect(state.completedText == nil)
    }

    @Test func cancelFromGeneratingResetsToInput() {
        let state = GenerationFlowState()
        state.phase = .generating
        state.streamingText = "partial"

        state.cancel()

        #expect(state.isInputPhase)
        #expect(state.streamingText.isEmpty)
    }

    @Test func cancelFromInputIsNoOp() {
        let state = GenerationFlowState()
        state.phase = .input
        state.streamingText = "leftover"

        state.cancel()

        #expect(state.isInputPhase)
        #expect(state.streamingText == "leftover")
    }

    @Test func cancelFromCompleteIsNoOp() {
        let state = GenerationFlowState()
        state.phase = .complete(text: "final")

        state.cancel()

        #expect(state.completedText == "final")
    }

    @Test func returnToInputResetsAllState() {
        let state = GenerationFlowState()
        state.phase = .complete(text: "plan")
        state.streamingText = "streamed"
        state.tokenUsage = TokenUsage(inputTokens: 10, outputTokens: 20)
        state.costEstimate = 0.05

        state.returnToInput()

        #expect(state.isInputPhase)
        #expect(state.streamingText.isEmpty)
        #expect(state.tokenUsage == nil)
        #expect(state.costEstimate == nil)
    }

    @Test func frozenFieldsPersistAcrossPhaseChanges() {
        let state = GenerationFlowState()
        state.frozenDescription = "my project"
        state.frozenModelName = "Claude"
        state.frozenModelID = "claude-4"
        state.frozenProviderID = "anthropic"

        state.phase = .generating
        state.phase = .complete(text: "done")

        #expect(state.frozenDescription == "my project")
        #expect(state.frozenModelName == "Claude")
        #expect(state.frozenModelID == "claude-4")
        #expect(state.frozenProviderID == "anthropic")
    }
}
