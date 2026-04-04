import XCTest
@testable import HoopoeUI

/// Tests for PromptTemplates — variable substitution and template completeness.
final class PromptTemplatesTests: XCTestCase {

    // MARK: - Variable Substitution

    func testSubstituteReplacesAllVariables() {
        let template = "Hello {name}, welcome to {project}!"
        let result = PromptTemplates.substitute(
            template: template,
            variables: ["name": "Alice", "project": "Hoopoe"]
        )

        XCTAssertEqual(result, "Hello Alice, welcome to Hoopoe!")
    }

    func testSubstituteWithEmptyVariables() {
        let template = "Hello {name}!"
        let result = PromptTemplates.substitute(template: template, variables: [:])

        XCTAssertEqual(result, "Hello {name}!", "Unmatched variables should remain as-is")
    }

    func testSubstituteReplacesMultipleOccurrences() {
        let template = "{x} + {x} = 2{x}"
        let result = PromptTemplates.substitute(
            template: template,
            variables: ["x": "1"]
        )

        XCTAssertEqual(result, "1 + 1 = 21")
    }

    func testSubstituteIgnoresExtraVariables() {
        let template = "Hello {name}!"
        let result = PromptTemplates.substitute(
            template: template,
            variables: ["name": "Bob", "unused": "value"]
        )

        XCTAssertEqual(result, "Hello Bob!")
    }

    // MARK: - Generation Template

    func testGenerationTemplateContainsAllRequiredSections() {
        let requiredSections = [
            "Goals",
            "Constraints",
            "Architecture",
            "Data Model",
            "API Design",
            "Failure Modes",
            "Testing Strategy",
            "Observability",
            "Security Considerations",
            "Rollout Plan",
            "Acceptance Criteria",
        ]

        for section in requiredSections {
            XCTAssertTrue(
                PromptTemplates.planGenerationUser.contains(section),
                "Generation template missing required section: \(section)"
            )
        }
    }

    func testGenerationTemplateContainsVariablePlaceholders() {
        let template = PromptTemplates.planGenerationUser
        XCTAssertTrue(template.contains("{project_name}"))
        XCTAssertTrue(template.contains("{project_description}"))
        XCTAssertTrue(template.contains("{tech_stack}"))
        XCTAssertTrue(template.contains("{platform}"))
    }

    func testGenerationSystemPromptEstablishesArchitectRole() {
        XCTAssertTrue(
            PromptTemplates.planGenerationSystem.lowercased().contains("software architect"),
            "System prompt should establish the architect role"
        )
    }

    // MARK: - Refinement Template

    func testRefinementTemplateContainsChecklist() {
        let template = PromptTemplates.planRefinementUser

        let checklistItems = [
            "Goals",
            "Constraints",
            "Architecture",
            "Data Model",
            "Failure Modes",
            "Testing",
            "Observability",
            "Security",
            "Rollout",
            "Acceptance Criteria",
        ]

        for item in checklistItems {
            XCTAssertTrue(
                template.contains(item),
                "Refinement template missing checklist item: \(item)"
            )
        }
    }

    func testRefinementTemplateRequestsCompleteOutput() {
        let template = PromptTemplates.planRefinementUser.lowercased()
        XCTAssertTrue(
            template.contains("complete refined plan") || template.contains("complete, improved"),
            "Refinement template should request complete output, not just suggestions"
        )
    }

    func testRefinementTemplateContainsVariablePlaceholders() {
        let template = PromptTemplates.planRefinementUser
        XCTAssertTrue(template.contains("{current_plan}"))
        XCTAssertTrue(template.contains("{refinement_round}"))
    }

    func testRefinementSystemPromptEstablishesReviewerRole() {
        let system = PromptTemplates.planRefinementSystem.lowercased()
        XCTAssertTrue(
            system.contains("review") || system.contains("refin"),
            "System prompt should establish reviewer/refiner role"
        )
    }

    // MARK: - Guided Question Templates

    func testGuidedQuestionSystemPromptRequestsJSON() {
        let system = PromptTemplates.guidedQuestionSystem
        XCTAssertTrue(system.contains("JSON"), "Guided system prompt should mention JSON format")
        XCTAssertTrue(system.contains("\"status\""), "Guided system prompt should show status field")
        XCTAssertTrue(system.contains("\"question\""), "Guided system prompt should show question field")
        XCTAssertTrue(system.contains("\"ready\""), "Guided system prompt should show ready status")
        XCTAssertTrue(system.contains("\"options\""), "Guided system prompt should show options field")
    }

    func testGuidedQuestionSystemPromptRequestsMultipleChoice() {
        let system = PromptTemplates.guidedQuestionSystem
        XCTAssertTrue(
            system.contains("Other..."),
            "Guided system prompt should instruct AI to include 'Other...' option"
        )
        XCTAssertTrue(
            system.lowercased().contains("multiple choice") || system.contains("3-5"),
            "Guided system prompt should request multiple choice options"
        )
    }

    func testGuidedQuestionUserTemplateContainsPlaceholders() {
        let template = PromptTemplates.guidedQuestionUser
        XCTAssertTrue(template.contains("{project_description}"))
        XCTAssertTrue(template.contains("{qa_history}"))
    }

    func testGuidedQuestionUserTemplateSubstitution() {
        let result = PromptTemplates.substitute(
            template: PromptTemplates.guidedQuestionUser,
            variables: [
                "project_description": "A weather tracking app",
                "qa_history": "Q: What platform?\nA: Web",
            ]
        )
        XCTAssertTrue(result.contains("A weather tracking app"))
        XCTAssertTrue(result.contains("Q: What platform?"))
        XCTAssertFalse(result.contains("{project_description}"))
        XCTAssertFalse(result.contains("{qa_history}"))
    }

    func testGuidedQuestionSystemPromptPreventsPlanGeneration() {
        let system = PromptTemplates.guidedQuestionSystem.lowercased()
        XCTAssertTrue(
            system.contains("do not generate the plan"),
            "Guided system prompt should prevent the AI from generating the plan"
        )
    }

    // MARK: - End-to-End Substitution

    func testGenerationTemplateSubstitution() {
        let result = PromptTemplates.substitute(
            template: PromptTemplates.planGenerationUser,
            variables: [
                "project_name": "Hoopoe",
                "project_description": "A macOS app for multi-agent development",
                "tech_stack": "Swift 6, Rust, UniFFI",
                "platform": "macOS 14+",
            ]
        )

        XCTAssertTrue(result.contains("Hoopoe"))
        XCTAssertTrue(result.contains("macOS 14+"))
        XCTAssertTrue(result.contains("Swift 6, Rust, UniFFI"))
        XCTAssertFalse(result.contains("{project_name}"), "All placeholders should be replaced")
        XCTAssertFalse(result.contains("{platform}"), "All placeholders should be replaced")
    }
}
