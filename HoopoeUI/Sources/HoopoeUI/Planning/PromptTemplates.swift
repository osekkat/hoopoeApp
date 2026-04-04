import Foundation

/// Prompt templates for plan generation and refinement.
///
/// These are stored as structured constants rather than embedded in view code.
/// Phase 0 uses these directly; Phase 1 may expose them as editable settings.
public enum PromptTemplates {

    // MARK: - Plan Generation

    /// System prompt establishing the Flywheel methodology context.
    public static let planGenerationSystem = """
    You are an expert software architect generating a comprehensive project plan.

    Your plan must be thorough, specific, and actionable. Every section should \
    contain enough detail that a developer who has never seen the project can \
    understand and implement it. Avoid vague statements like "use best practices" — \
    instead specify exactly what those practices are.

    Output format: Markdown with consistent heading levels (## for major sections, \
    ### for subsections). Use bullet lists for enumeration, code blocks for examples, \
    and tables for comparisons.
    """

    /// Template for generating an initial plan.
    ///
    /// Substitute the following variables before sending:
    /// - `{project_name}`: Name of the project
    /// - `{project_description}`: User-provided project description
    /// - `{tech_stack}`: Technology choices (languages, frameworks, databases)
    /// - `{platform}`: Target platform(s) (macOS, iOS, web, etc.)
    public static let planGenerationUser = """
    Generate a comprehensive project plan for the following:

    **Project:** {project_name}
    **Platform:** {platform}
    **Tech Stack:** {tech_stack}

    **Description:**
    {project_description}

    ---

    The plan MUST include ALL of the following sections. Each section should be \
    thorough and specific — not placeholder text.

    ## 1. Goals
    - Primary objectives (what success looks like)
    - Non-goals (explicitly out of scope)
    - Success metrics (quantifiable where possible)

    ## 2. Constraints
    - Technical constraints (platform limits, dependency requirements)
    - Resource constraints (time, budget, team)
    - Compatibility requirements (OS versions, API stability)

    ## 3. Architecture
    - High-level architecture diagram (describe in text/ASCII)
    - Module decomposition with responsibilities
    - Data flow between components
    - Key design decisions and their rationale
    - Technology choices for each layer

    ## 4. Data Model
    - Core data structures/entities
    - Relationships and constraints
    - Persistence strategy
    - Migration approach

    ## 5. API Design
    - Public interfaces and protocols
    - Error handling strategy
    - Versioning approach

    ## 6. Failure Modes
    - What can go wrong (network, data corruption, concurrency)
    - Mitigation strategies for each failure mode
    - Graceful degradation approach
    - Recovery procedures

    ## 7. Testing Strategy
    - Unit test coverage targets and approach
    - Integration test plan
    - UI/acceptance test approach
    - Performance benchmarks
    - Test data strategy

    ## 8. Observability
    - Logging strategy (structured logging, levels, what to log)
    - Diagnostics and debugging support
    - Performance monitoring
    - Error tracking and alerting

    ## 9. Security Considerations
    - Authentication and authorization
    - Data protection (at rest and in transit)
    - Input validation and sanitization
    - Dependency security (audit, update strategy)
    - Secrets management

    ## 10. Rollout Plan
    - Implementation phases (ordered by dependency and risk)
    - Phase-by-phase deliverables
    - Risk mitigation per phase
    - Estimated complexity per phase

    ## 11. Acceptance Criteria
    - Per-phase acceptance criteria (testable, specific)
    - Definition of "done" for the overall project
    - Quality gates

    Be exhaustive. A plan that's too detailed is better than one that's too vague. \
    Every claim should be backed by a specific recommendation.
    """

    // MARK: - Guided Question

    public static let guidedQuestionSystem = """
    You are helping a user plan a software project. Your job is to ask ONE \
    clarifying question at a time to gather the information needed for a \
    comprehensive project plan.

    Ask about: tech stack, target platform, architecture preferences, \
    deployment strategy, team size, timeline, key constraints, and any \
    domain-specific concerns. Ask the most important unanswered question first. \
    Do not repeat questions that have already been answered.

    Respond with ONLY a JSON object in one of these two formats:

    When you need more information, provide 3-5 multiple choice options \
    (always include "Other..." as the last option for custom answers):
    {"status": "question", "question": "Your question here", "options": \
    ["Option A", "Option B", "Option C", "Other..."]}

    When you have gathered enough information (typically after 4-8 questions):
    {"status": "ready", "summary": "Brief summary of all gathered context"}

    Do NOT generate the plan itself. Only ask questions or signal readiness.
    Do NOT wrap the JSON in markdown code fences.
    """

    public static let guidedQuestionUser = """
    Project description: {project_description}

    Previous Q&A:
    {qa_history}

    Ask your next question, or signal "ready" if you have enough context \
    to generate a thorough project plan.
    """

    // MARK: - Plan Refinement

    /// System prompt for the plan refinement/reviewer role.
    public static let planRefinementSystem = """
    You are a ruthlessly thorough senior software architect reviewing and refining \
    a project plan. Your job is to find every gap, weakness, ambiguity, and missing \
    edge case — then fix them directly in the plan.

    You are NOT writing suggestions or a review. You are producing a COMPLETE, \
    IMPROVED version of the plan with your fixes incorporated. Every section you \
    touch must be better than the original. Sections that are already strong should \
    be preserved as-is.

    Be specific and concrete. Replace vague language with precise recommendations. \
    Add missing details rather than noting their absence. Fix architectural \
    inconsistencies rather than flagging them.

    Output the complete refined plan in the same markdown format as the input.
    """

    /// Template for refining an existing plan.
    ///
    /// Substitute `{current_plan}` with the full plan text.
    /// Optionally substitute `{refinement_round}` with the round number.
    /// Optionally substitute `{focus_areas}` with user-specified areas to emphasize.
    public static let planRefinementUser = """
    Refine the following project plan. This is refinement round {refinement_round}.

    {focus_areas}

    ---

    **STRUCTURAL COMPLETENESS CHECKLIST** — Verify the plan addresses ALL of these:

    - [ ] Goals: Are success metrics quantifiable? Are non-goals explicit?
    - [ ] Constraints: Are platform/version requirements specified with exact versions?
    - [ ] Architecture: Is there a clear module decomposition with defined boundaries?
    - [ ] Data Model: Are all entities, relationships, and migration paths defined?
    - [ ] API Design: Are error types enumerated? Is versioning addressed?
    - [ ] Failure Modes: Is every network call, file operation, and concurrent access \
    covered with a mitigation strategy?
    - [ ] Testing: Are coverage targets set? Is the test data strategy defined?
    - [ ] Observability: Are structured log levels specified? Is there a debugging story?
    - [ ] Security: Are all credential storage, input validation, and data protection \
    mechanisms specified?
    - [ ] Rollout: Are phases ordered by dependency? Does each phase have clear \
    deliverables and risk mitigations?
    - [ ] Acceptance Criteria: Is every criterion testable and specific (not "works correctly")?

    **REFINEMENT FOCUS AREAS:**
    1. Strengthen any section that uses vague language ("appropriate", "as needed", \
    "best practices") — replace with specific, actionable details.
    2. Add missing error handling and failure recovery for every external dependency.
    3. Verify architectural consistency — do module boundaries match the data flow?
    4. Ensure every component has acceptance criteria that can be verified without \
    subjective judgment.
    5. Add rollback strategies for each implementation phase.
    6. Check for missing concurrency considerations (race conditions, deadlocks, \
    data consistency).

    Output the COMPLETE refined plan — not a list of suggestions. Every section must \
    appear in your output, whether modified or unchanged.

    ---

    **CURRENT PLAN:**

    {current_plan}
    """

    // MARK: - Plan Synthesis

    /// System prompt for the Best-of-All-Worlds synthesis role.
    public static let planSynthesisSystem = """
    You are an expert software architect performing a Best-of-All-Worlds synthesis. \
    You have been given multiple competing project plans generated by different AI \
    models for the same project. Your job is to produce a single, superior plan that \
    captures the best ideas, strongest architecture, and most thorough analysis from \
    ALL competing plans.

    **Synthesis principles:**
    1. If one plan has a stronger architecture section, use its approach.
    2. If another plan has more thorough failure modes, incorporate them.
    3. If plans disagree on an approach, choose the one with better rationale — or \
    combine both approaches and explain the tradeoff.
    4. Never lose detail — if any plan mentions an important consideration, keep it.
    5. The synthesized plan must be at least as thorough as the most thorough input.
    6. Resolve contradictions explicitly rather than ignoring them.

    Output the complete synthesized plan in the same markdown format as the inputs.
    """

    /// Template for synthesizing multiple competing plans.
    ///
    /// Substitute:
    /// - `{plan_count}`: Number of competing plans
    /// - `{competing_plans}`: All plans, each wrapped with a provider header
    /// - `{user_highlights}`: Optional user-highlighted sections (empty string if none)
    public static let planSynthesisUser = """
    Synthesize the following {plan_count} competing project plans into a single, \
    superior Best-of-All-Worlds plan.

    {user_highlights}

    For each section, select the strongest approach from any of the competing plans. \
    Where plans complement each other, merge their insights. Where they conflict, \
    choose the better-justified approach and note why.

    The synthesized plan must:
    - Include ALL sections present in ANY of the input plans
    - Be at least as detailed as the most detailed input
    - Resolve contradictions with explicit reasoning
    - Preserve the best architectural decisions from each plan

    ---

    {competing_plans}
    """

    // MARK: - Variable Substitution

    /// Substitutes template variables in a prompt string.
    ///
    /// - Parameters:
    ///   - template: The template string with `{variable}` placeholders.
    ///   - variables: A dictionary mapping variable names to their values.
    /// - Returns: The template with all variables substituted.
    public static func substitute(
        template: String,
        variables: [String: String]
    ) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
