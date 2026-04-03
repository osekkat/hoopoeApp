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

    func testGenerationSystemPromptMentionsFlywheel() {
        XCTAssertTrue(
            PromptTemplates.planGenerationSystem.lowercased().contains("flywheel"),
            "System prompt should reference the Flywheel methodology"
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
