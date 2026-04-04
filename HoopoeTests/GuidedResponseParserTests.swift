import Testing
@testable import Hoopoe

@Suite("GuidedResponseParser")
struct GuidedResponseParserTests {

    // MARK: - Question Parsing

    @Test func validQuestionWithOptions() {
        let json = """
        {"status": "question", "question": "What tech stack?", "options": ["React", "Vue", "Angular", "Other..."]}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .question(let q, let opts) = result else {
            Issue.record("Expected .question, got \(result)")
            return
        }
        #expect(q == "What tech stack?")
        #expect(opts == ["React", "Vue", "Angular", "Other..."])
    }

    @Test func questionWithoutOptionsReturnsEmptyArray() {
        let json = """
        {"status": "question", "question": "What is your timeline?"}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .question(let q, let opts) = result else {
            Issue.record("Expected .question, got \(result)")
            return
        }
        #expect(q == "What is your timeline?")
        #expect(opts.isEmpty)
    }

    @Test func questionWithEmptyOptionsArray() {
        let json = """
        {"status": "question", "question": "Describe your goals.", "options": []}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .question(let q, let opts) = result else {
            Issue.record("Expected .question, got \(result)")
            return
        }
        #expect(q == "Describe your goals.")
        #expect(opts.isEmpty)
    }

    // MARK: - Ready Parsing

    @Test func readyStatus() {
        let json = """
        {"status": "ready", "summary": "Enough context gathered."}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .ready = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
    }

    @Test func readyStatusWithoutSummary() {
        let json = """
        {"status": "ready"}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .ready = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
    }

    // MARK: - Code Fence Stripping

    @Test func stripsJsonCodeFence() {
        let json = """
        ```json
        {"status": "ready", "summary": "Done"}
        ```
        """
        let result = GuidedResponseParser.parse(json)
        guard case .ready = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
    }

    @Test func stripsPlainCodeFence() {
        let json = """
        ```
        {"status": "question", "question": "Platform?", "options": ["iOS", "macOS"]}
        ```
        """
        let result = GuidedResponseParser.parse(json)
        guard case .question(let q, let opts) = result else {
            Issue.record("Expected .question, got \(result)")
            return
        }
        #expect(q == "Platform?")
        #expect(opts == ["iOS", "macOS"])
    }

    // MARK: - Parse Error Cases

    @Test func plainTextReturnsParseError() {
        let result = GuidedResponseParser.parse("I think you should use React.")
        guard case .parseError(let raw) = result else {
            Issue.record("Expected .parseError, got \(result)")
            return
        }
        #expect(raw == "I think you should use React.")
    }

    @Test func emptyStringReturnsParseError() {
        let result = GuidedResponseParser.parse("")
        guard case .parseError = result else {
            Issue.record("Expected .parseError, got \(result)")
            return
        }
    }

    @Test func invalidJsonReturnsParseError() {
        let result = GuidedResponseParser.parse("{broken json")
        guard case .parseError = result else {
            Issue.record("Expected .parseError, got \(result)")
            return
        }
    }

    @Test func missingStatusFieldReturnsParseError() {
        let json = """
        {"question": "What stack?", "options": ["A", "B"]}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .parseError = result else {
            Issue.record("Expected .parseError, got \(result)")
            return
        }
    }

    @Test func unknownStatusReturnsParseError() {
        let json = """
        {"status": "thinking", "note": "still processing"}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .parseError = result else {
            Issue.record("Expected .parseError, got \(result)")
            return
        }
    }

    @Test func questionStatusWithoutQuestionFieldReturnsParseError() {
        let json = """
        {"status": "question", "options": ["A", "B"]}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .parseError = result else {
            Issue.record("Expected .parseError, got \(result)")
            return
        }
    }

    // MARK: - Whitespace and Formatting

    @Test func handlesLeadingTrailingWhitespace() {
        let json = """
        
          {"status": "ready"}
        
        """
        let result = GuidedResponseParser.parse(json)
        guard case .ready = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
    }

    @Test func handlesNewlinesInCodeFence() {
        let json = "```json\n{\"status\": \"question\", \"question\": \"Stack?\", \"options\": [\"A\"]}\n```"
        let result = GuidedResponseParser.parse(json)
        guard case .question(let q, _) = result else {
            Issue.record("Expected .question, got \(result)")
            return
        }
        #expect(q == "Stack?")
    }

    @Test func unicodeInQuestionAndOptions() {
        let json = """
        {"status": "question", "question": "Quelle plateforme?", "options": ["macOS", "iOS", "Autre..."]}
        """
        let result = GuidedResponseParser.parse(json)
        guard case .question(let q, let opts) = result else {
            Issue.record("Expected .question, got \(result)")
            return
        }
        #expect(q == "Quelle plateforme?")
        #expect(opts.contains("Autre..."))
    }
}
