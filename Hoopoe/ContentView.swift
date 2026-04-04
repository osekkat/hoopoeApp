import HoopoeUI
import HoopoeUtils
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar Selection

enum SidebarSelection: Hashable {
    case plan(UUID)
    case newPlan
}

// MARK: - Routes

enum HoopoeRoute: Codable, Hashable, Sendable {
    case plansHome
    case planEditor(planId: UUID)
    case planGeneration
    case planWizard
    case multiModelSynthesis(planId: UUID)
    case refinement(planId: UUID)
    case versionHistory(planId: UUID)

    var title: String {
        switch self {
        case .plansHome:
            "Plans"
        case .planEditor:
            "Plan Editor"
        case .planGeneration:
            "Plan Generation"
        case .planWizard:
            "New Plan Wizard"
        case .multiModelSynthesis:
            "Multi-Model Synthesis"
        case .refinement:
            "Refinement"
        case .versionHistory:
            "Version History"
        }
    }

    var planID: UUID? {
        switch self {
        case let .planEditor(planId),
            let .multiModelSynthesis(planId),
            let .refinement(planId),
            let .versionHistory(planId):
            planId
        case .plansHome, .planGeneration, .planWizard:
            nil
        }
    }
}

// MARK: - Router

@MainActor
@Observable
final class NavigationRouter {
    static let samplePlanID = UUID(uuidString: "9A40E5A4-BB46-4D9F-A8B2-1803D568F8E0")!

    private(set) var currentRoute: HoopoeRoute?
    private(set) var backStack: [HoopoeRoute]
    private(set) var forwardStack: [HoopoeRoute] = []

    init(initialRoute: HoopoeRoute? = .plansHome, backStack: [HoopoeRoute] = []) {
        self.currentRoute = initialRoute
        self.backStack = backStack
    }

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    var selectedSidebarSelection: SidebarSelection? {
        guard let currentRoute else {
            return nil
        }

        switch currentRoute {
        case let .planEditor(planId),
            let .multiModelSynthesis(planId),
            let .refinement(planId),
            let .versionHistory(planId):
            return .plan(planId)
        case .planGeneration, .planWizard:
            return .newPlan
        case .plansHome:
            return nil
        }
    }

    func handleSidebarSelection(_ selection: SidebarSelection?) {
        guard let selection else {
            return
        }

        switch selection {
        case .newPlan:
            navigate(to: .planWizard)
        case let .plan(planId):
            navigate(to: .planEditor(planId: planId))
        }
    }

    func navigate(to route: HoopoeRoute) {
        guard currentRoute != route else {
            return
        }

        if let currentRoute {
            backStack.append(currentRoute)
        }

        currentRoute = route
        forwardStack.removeAll()
    }

    func goBack() {
        guard let previousRoute = backStack.popLast() else {
            return
        }

        if let currentRoute {
            forwardStack.append(currentRoute)
        }

        currentRoute = previousRoute
    }

    func goForward() {
        guard let nextRoute = forwardStack.popLast() else {
            return
        }

        if let currentRoute {
            backStack.append(currentRoute)
        }

        currentRoute = nextRoute
    }
}

// MARK: - Main Content View

private enum SamplePlanSeed {
    static let title = "Hoopoe Planning Sandbox"
    static let content = """
    # Hoopoe Planning Sandbox

    ## Goals
    - Capture the project vision in a form that can survive multiple refinement rounds.
    - Keep the editor responsive while long markdown documents grow.
    - Make section-level navigation easy from surrounding SwiftUI controls.

    ## Constraints
    - The editing surface is AppKit-backed for performance.
    - The hosting shell is SwiftUI and should own navigation state.
    - Cursor position must survive SwiftUI update passes.

    ## Architecture
    - `PlanEditorRepresentable` bridges SwiftUI into `PlanEditorView`.
    - `PlanEditorProxy` exposes scroll, insert, and selection commands.
    - The editor route owns the bound markdown string and secondary controls.

    ## Testing Strategy
    - Verify typing does not flicker or recreate the editor.
    - Verify toolbar actions mutate or navigate the AppKit view.
    - Verify selection state flows back into SwiftUI.
    """
}

struct ContentView: View {
    private let settings = AppSettings.shared
    @State private var router = NavigationRouter()
    @State private var inspectorIsVisible = true
    @State private var planStore: PlanStore
    @State private var versionManager: PlanVersionManager

    init() {
        let store = PlanStore(directory: AppSettings.shared.defaultSaveDirectory)
        try? store.loadAll()
        Self.ensureSamplePlan(in: store)
        _planStore = State(initialValue: store)
        _versionManager = State(initialValue: PlanVersionManager(store: store))
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { router.selectedSidebarSelection },
            set: { router.handleSidebarSelection($0) }
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: sidebarSelection, planStore: planStore, router: router)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            HSplitView {
                mainContent
                    .frame(minWidth: 400)

                if inspectorIsVisible {
                    InspectorPanel(route: router.currentRoute, router: router)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .focusedValue(\.planStore, planStore)
        .focusedValue(\.router, router)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: settings.defaultSaveDirectory) { _, newDirectory in
            reloadPlanStore(for: newDirectory)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    router.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!router.canGoBack)
                .help("Navigate back")

                Button {
                    router.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!router.canGoForward)
                .help("Navigate forward")

                Button {
                    withAnimation {
                        inspectorIsVisible.toggle()
                    }
                } label: {
                    Label(
                        inspectorIsVisible ? "Hide Inspector" : "Show Inspector",
                        systemImage: "sidebar.trailing"
                    )
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(inspectorIsVisible ? "Hide Inspector" : "Show Inspector")
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch router.currentRoute {
        case .plansHome:
            PlansHomeView(router: router)
        case let .planEditor(planId):
            if let plan = plan(for: planId) {
                PlanEditorRouteView(plan: plan, router: router)
            } else {
                MissingPlanRouteView(planId: planId, router: router)
            }
        case .planGeneration:
            PlanGenerationView(router: router, planStore: planStore)
        case .planWizard:
            PlanWizardView(router: router, planStore: planStore)
        case let .multiModelSynthesis(planId):
            if let plan = plan(for: planId) {
                CompetingPlansView(plan: plan, planStore: planStore, router: router)
            } else {
                MissingPlanRouteView(planId: planId, router: router)
            }
        case let .refinement(planId):
            if let plan = plan(for: planId) {
                RefinementPanelView(plan: plan, versionManager: versionManager)
            } else {
                MissingPlanRouteView(planId: planId, router: router)
            }
        case let .versionHistory(planId):
            if let plan = plan(for: planId) {
                VersionListView(plan: plan, versionManager: versionManager, router: router)
            } else {
                MissingPlanRouteView(planId: planId, router: router)
            }
        case nil:
            NoSelectionView()
        }
    }

    private func plan(for id: UUID) -> PlanDocument? {
        planStore.plans.first { $0.id == id }
    }

    private func reloadPlanStore(for directory: URL) {
        planStore.saveAllDirty()
        planStore.storeDirectory = directory
        try? planStore.loadAll()
        Self.ensureSamplePlan(in: planStore)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "md"
                else { return }

                Task { @MainActor in
                    if let plan = PlanImporter.importFile(at: url, into: planStore) {
                        router.navigate(to: .planEditor(planId: plan.id))
                    }
                }
            }
            handled = true
        }
        return handled
    }

    private static func ensureSamplePlan(in store: PlanStore) {
        guard store.plans.contains(where: { $0.id == NavigationRouter.samplePlanID }) == false else {
            return
        }

        let samplePlan = store.createPlan(
            id: NavigationRouter.samplePlanID,
            title: SamplePlanSeed.title,
            content: SamplePlanSeed.content
        )
        try? store.save(samplePlan)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    let planStore: PlanStore
    let router: NavigationRouter

    @State private var planToDelete: PlanDocument?
    @State private var planToRename: PlanDocument?
    @State private var renameText = ""

    private var sortedPlans: [PlanDocument] {
        planStore.plans.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Plans") {
                if sortedPlans.isEmpty {
                    emptyState
                } else {
                    ForEach(sortedPlans) { plan in
                        PlanRowView(plan: plan)
                            .tag(SidebarSelection.plan(plan.id))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                openPlan(plan)
                            }
                            .contextMenu {
                                planContextMenu(for: plan)
                            }
                    }
                }
            }

            Section {
                Label("New Plan", systemImage: "plus.square")
                    .tag(SidebarSelection.newPlan)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openPlanWizard()
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hoopoe")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    openPlanWizard()
                } label: {
                    Label("New Plan", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        .alert(
            "Delete Plan?",
            isPresented: Binding(
                get: { planToDelete != nil },
                set: { if !$0 { planToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let plan = planToDelete {
                    deletePlan(plan)
                }
            }
            Button("Cancel", role: .cancel) {
                planToDelete = nil
            }
        } message: {
            if let plan = planToDelete {
                Text("Are you sure you want to delete \"\(plan.title)\"? This cannot be undone.")
            }
        }
        .sheet(isPresented: Binding(
            get: { planToRename != nil },
            set: { if !$0 { planToRename = nil } }
        )) {
            if let plan = planToRename {
                renameSheet(for: plan)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No plans yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Create a new plan or import a .md file.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func planContextMenu(for plan: PlanDocument) -> some View {
        Button {
            renameText = plan.title
            planToRename = plan
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        if let filePath = plan.filePath {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([filePath])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }

        Divider()

        Button(role: .destructive) {
            planToDelete = plan
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Rename Sheet

    private func renameSheet(for plan: PlanDocument) -> some View {
        VStack(spacing: 16) {
            Text("Rename Plan")
                .font(.headline)

            TextField("Plan title", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack {
                Button("Cancel") {
                    planToRename = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return
                    }

                    let previousTitle = plan.title
                    let previousUpdatedAt = plan.updatedAt
                    plan.title = trimmed
                    plan.updatedAt = Date()

                    do {
                        try planStore.save(plan)
                        planToRename = nil
                    } catch {
                        plan.title = previousTitle
                        plan.updatedAt = previousUpdatedAt
                        presentErrorAlert(error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Actions

    private func deletePlan(_ plan: PlanDocument) {
        let wasSelected = router.currentRoute?.planID == plan.id
        do {
            try planStore.delete(plan)
            if wasSelected {
                router.navigate(to: .plansHome)
            }
        } catch {
            presentErrorAlert(error)
        }
        planToDelete = nil
    }

    private func openPlan(_ plan: PlanDocument) {
        router.navigate(to: .planEditor(planId: plan.id))
    }

    private func openPlanWizard() {
        router.navigate(to: .planWizard)
    }

    private func presentErrorAlert(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}

// MARK: - Plan Row View

struct PlanRowView: View {
    let plan: PlanDocument

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(.callout)
                    .lineLimit(1)

                Text(plan.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if plan.versions.count > 0 {
                Text("R\(plan.versions.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Inspector Panel

struct InspectorPanel: View {
    let route: HoopoeRoute?
    let router: NavigationRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.headline)
                .padding(.bottom, 4)

            if let route {
                Text(route.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let planId = route.planID {
                    Text("Plan ID: \(planId.uuidString)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            } else {
                Text("No selection")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            Text("Back stack: \(router.backStack.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Forward stack: \(router.forwardStack.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

// MARK: - Route Views

struct PlansHomeView: View {
    let router: NavigationRouter
    private let settings = AppSettings.shared

    var body: some View {
        if settings.hasCompletedOnboarding {
            RoutePlaceholderCard(
                systemImage: "doc.text.magnifyingglass",
                title: "Plans",
                message: "Select a plan from the sidebar to start editing, or create a new one."
            ) {
                Button("Create New Plan") {
                    router.navigate(to: .planGeneration)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            OnboardingCardView(router: router)
        }
    }
}

// MARK: - Onboarding Card

struct OnboardingCardView: View {
    let router: NavigationRouter
    @Environment(\.openSettings) private var openSettings
    private let settings = AppSettings.shared
    @State private var hasProviders = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bird")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Welcome to Hoopoe")
                .font(.largeTitle.weight(.semibold))

            Text("Hoopoe helps you create exhaustive, high-quality project plans using AI. Configure your API keys to enable AI-powered generation, then create your first plan.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            VStack(spacing: 12) {
                if hasProviders {
                    Button {
                        completeOnboarding()
                        router.navigate(to: .planGeneration)
                    } label: {
                        Label("Create Your First Plan", systemImage: "wand.and.stars")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        completeOnboarding()
                        showSettings()
                    } label: {
                        Label("Configure API Keys", systemImage: "key")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        completeOnboarding()
                        showSettings()
                    } label: {
                        Label("Configure API Keys", systemImage: "key")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        completeOnboarding()
                        router.navigate(to: .planGeneration)
                    } label: {
                        Label("Create Your First Plan", systemImage: "wand.and.stars")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Button("Skip") {
                completeOnboarding()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .task {
            await checkProviders()
        }
    }

    private func completeOnboarding() {
        settings.hasCompletedOnboarding = true
    }

    private func showSettings() {
        openSettings()
    }

    private func checkProviders() async {
        let keychain = KeychainService()
        for provider in KeychainService.Provider.allCases {
            let accounts = (try? await keychain.listAccounts(provider: provider.rawValue)) ?? []
            if !accounts.isEmpty {
                hasProviders = true
                return
            }
        }
    }
}

struct PlanEditorRouteView: View {
    let plan: PlanDocument
    let router: NavigationRouter
    private let settings = AppSettings.shared
    @State private var editorProxy = PlanEditorProxy()
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var previewMode: PreviewMode = .editorOnly
    @State private var previewMarkdown = ""
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        editorContent
            .focusedValue(\.plan, plan)
            .focusedValue(\.previewMode, $previewMode)
            .focusedValue(\.editorFormatting, EditorFormatting(
                bold: { wrapSelection(prefix: "**", suffix: "**") },
                italic: { wrapSelection(prefix: "*", suffix: "*") }
            ))
            .onAppear { previewMarkdown = plan.content }
            .onChange(of: plan.content) { _, newValue in
                debouncePreviewUpdate(newValue)
            }
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            editorToolbar

            Divider()

            switch previewMode {
            case .editorOnly:
                editorPane
            case .split:
                HSplitView {
                    editorPane
                        .frame(minWidth: 300)
                    previewPane
                        .frame(minWidth: 300)
                }
            case .previewOnly:
                previewPane
            }
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        VStack(spacing: 0) {
            // Primary toolbar: title, preview, navigation
            HStack(spacing: 12) {
                Text(plan.title)
                    .font(.title3.weight(.semibold))

                Spacer()

                Picker("Preview", selection: $previewMode) {
                    ForEach(PreviewMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Button("Refinement") {
                    router.navigate(to: .refinement(planId: plan.id))
                }
                .buttonStyle(.borderedProminent)

                Button("Version History") {
                    router.navigate(to: .versionHistory(planId: plan.id))
                }
                .buttonStyle(.bordered)

                Button("Synthesis") {
                    router.navigate(to: .multiModelSynthesis(planId: plan.id))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Formatting toolbar
            HStack(spacing: 4) {
                // Formatting buttons
                Group {
                    formatButton(icon: "bold", tooltip: "Bold (Cmd+B)") {
                        wrapSelection(prefix: "**", suffix: "**")
                    }
                    formatButton(icon: "italic", tooltip: "Italic (Cmd+I)") {
                        wrapSelection(prefix: "*", suffix: "*")
                    }
                    formatButton(icon: "chevron.left.forwardslash.chevron.right", tooltip: "Inline Code") {
                        wrapSelection(prefix: "`", suffix: "`")
                    }

                    Divider().frame(height: 16)

                    // Heading picker
                    Menu {
                        Button("Heading 1") { insertLinePrefix("# ") }
                        Button("Heading 2") { insertLinePrefix("## ") }
                        Button("Heading 3") { insertLinePrefix("### ") }
                        Button("Heading 4") { insertLinePrefix("#### ") }
                    } label: {
                        Label("Heading", systemImage: "textformat.size")
                            .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 32)

                    Divider().frame(height: 16)

                    formatButton(icon: "list.bullet", tooltip: "Bullet List") {
                        insertLinePrefix("- ")
                    }
                    formatButton(icon: "list.number", tooltip: "Numbered List") {
                        insertLinePrefix("1. ")
                    }
                    formatButton(icon: "text.quote", tooltip: "Blockquote") {
                        insertLinePrefix("> ")
                    }
                    formatButton(icon: "curlybraces", tooltip: "Code Block") {
                        wrapSelection(prefix: "```\n", suffix: "\n```")
                    }
                    formatButton(icon: "link", tooltip: "Link") {
                        insertLink()
                    }
                }

                Divider().frame(height: 16)

                // Section navigation
                sectionNavigationMenu

                Spacer()

                // Word count
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    private func formatButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private var sectionNavigationMenu: some View {
        Menu {
            if headings.isEmpty {
                Text("No headings")
            } else {
                ForEach(headings, id: \.offset) { heading in
                    Button {
                        editorProxy.scrollToSection(heading.text)
                    } label: {
                        Text(String(repeating: "  ", count: heading.level - 1) + heading.text)
                    }
                }
            }
        } label: {
            Label("Sections", systemImage: "list.bullet.indent")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32)
        .help("Jump to section")
    }

    // MARK: - Headings

    private struct Heading {
        let text: String
        let level: Int
        let offset: Int
    }

    private var headings: [Heading] {
        var result: [Heading] = []
        var offset = 0
        for line in plan.content.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                var level = 0
                for ch in line { if ch == "#" { level += 1 } else { break } }
                if level >= 1, level <= 6, line.count > level,
                   line[line.index(line.startIndex, offsetBy: level)] == " "
                {
                    let text = String(line.dropFirst(level + 1))
                    result.append(Heading(text: text, level: level, offset: offset))
                }
            }
            offset += line.count + 1 // +1 for newline
        }
        return result
    }

    // MARK: - Formatting Actions

    private func wrapSelection(prefix: String, suffix: String) {
        let content = plan.content
        let nsContent = content as NSString
        let range = selectedRange
        if range.length > 0 {
            let selected = nsContent.substring(with: range)
            editorProxy.insertText("\(prefix)\(selected)\(suffix)")
        } else {
            editorProxy.insertText("\(prefix)\(suffix)")
        }
    }

    private func insertLinePrefix(_ prefix: String) {
        let content = plan.content
        let nsContent = content as NSString
        // Find the start of the current line
        let lineRange = nsContent.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let lineText = nsContent.substring(with: lineRange)
        // Strip existing heading prefix if present
        var stripped = lineText
        if stripped.hasPrefix("#") {
            // Remove existing heading markers
            while stripped.hasPrefix("#") { stripped = String(stripped.dropFirst()) }
            if stripped.hasPrefix(" ") { stripped = String(stripped.dropFirst()) }
        }
        let replacement = prefix + stripped
        editorProxy.selectRange(lineRange)
        editorProxy.insertText(replacement)
    }

    private func insertLink() {
        let range = selectedRange
        let nsContent = plan.content as NSString
        if range.length > 0 {
            let selected = nsContent.substring(with: range)
            editorProxy.insertText("[\(selected)](url)")
        } else {
            editorProxy.insertText("[link text](url)")
        }
    }

    // MARK: - Editor Pane

    private var editorPane: some View {
        PlanEditorRepresentable(
            text: planTextBinding,
            configuration: editorConfiguration,
            proxy: editorProxy
        ) { range in
            selectedRange = range
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        MarkdownPreviewRepresentable(
            markdown: previewMarkdown,
            scrollFraction: scrollFraction
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Approximate scroll fraction based on cursor position within the text.
    private var scrollFraction: CGFloat {
        let total = max(plan.content.count, 1)
        return CGFloat(selectedRange.location) / CGFloat(total)
    }

    private func debouncePreviewUpdate(_ text: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            previewMarkdown = text
        }
    }

    private var wordCount: Int {
        plan.metadata.wordCount
    }

    private var planTextBinding: Binding<String> {
        Binding(
            get: { plan.content },
            set: { updatedText in
                guard plan.content != updatedText else {
                    return
                }
                plan.content = updatedText
                plan.updatedAt = Date()
            }
        )
    }

    private var editorConfiguration: PlanEditorConfiguration {
        PlanEditorConfiguration(
            fontSize: CGFloat(settings.editorFontSize),
            wrapsLines: settings.editorLineWrapping,
            showsLineNumbers: settings.editorShowLineNumbers,
            themeID: settings.editorTheme.rawValue,
            markdownTheme: editorMarkdownTheme
        )
    }

    private var editorMarkdownTheme: MarkdownTheme {
        switch settings.editorTheme {
        case .light:
            .light
        case .dark:
            .dark
        case .system:
            .default
        }
    }

    private func sectionRange(named heading: String) -> NSRange {
        let headingMarker = "## \(heading)"
        let contentNSString = plan.content as NSString
        let match = contentNSString.range(of: headingMarker)
        guard match.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        return contentNSString.lineRange(for: match)
    }
}

struct MissingPlanRouteView: View {
    let planId: UUID
    let router: NavigationRouter

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "exclamationmark.triangle",
            title: "Plan Not Found",
            message: "The selected plan could not be loaded. The editor route now refuses to fall back to unrelated placeholder content."
        ) {
            Text(planId.uuidString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Button("Return to Plans") {
                router.navigate(to: .plansHome)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Shared Views

struct RoutePlaceholderCard<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let actions: Actions

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(message)
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct NoSelectionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a plan or create a new one")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Project Picker

struct ProjectPickerView: View {
    let onOpen: (URL) -> Void

    @State private var isDropTargeted = false
    @State private var showNewProjectSheet = false

    var body: some View {
        VStack(spacing: 32) {
            dropZone
            newProjectRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet(onOpen: onOpen)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Open Project")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Text("Drag a folder with .git or click to browse")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 520, minHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [8, 5])
                )
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture { browseForProject() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - New Project

    private var newProjectRow: some View {
        HStack(spacing: 12) {
            Text("Or start a new project")
                .foregroundStyle(.secondary)

            Button {
                showNewProjectSheet = true
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    private func browseForProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Select a folder containing a git repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if isGitRepo(url) {
            onOpen(url)
        } else {
            showNotGitRepoAlert(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue
                else { return }

                Task { @MainActor in
                    if isGitRepo(url) {
                        onOpen(url)
                    } else {
                        showNotGitRepoAlert(url)
                    }
                }
            }
        }
        return true
    }

    private func isGitRepo(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let gitPath = url.appendingPathComponent(".git").path
        return FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
    }

    private func initGitRepo(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = url
        try? process.run()
        process.waitUntilExit()
    }

    private func showNotGitRepoAlert(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Not a Git Repository"
        alert.informativeText = "\"\(url.lastPathComponent)\" does not contain a .git directory. Would you like to initialize one?"
        alert.addButton(withTitle: "Initialize Git")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            initGitRepo(at: url)
            onOpen(url)
        }
    }
}

// MARK: - New Project Sheet

private struct NewProjectSheet: View {
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var cloneURL = ""
    @State private var isCloning = false
    @State private var cloneError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("New Project")
                .font(.title3.weight(.semibold))
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            // Options
            VStack(spacing: 0) {
                // Create from scratch
                optionRow(
                    icon: "folder.badge.plus",
                    title: "Create Empty Repository",
                    subtitle: "Pick a folder and initialize a new git repo"
                ) {
                    createFromScratch()
                }

                Divider().padding(.horizontal, 20)

                // Clone
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clone Repository")
                                .font(.body.weight(.medium))
                            Text("Clone an existing git repository by URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 14)

                    HStack(spacing: 8) {
                        TextField("https://github.com/user/repo.git", text: $cloneURL)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isCloning)

                        Button {
                            cloneRepo()
                        } label: {
                            if isCloning {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 50)
                            } else {
                                Text("Clone")
                                    .frame(width: 50)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(cloneURL.trimmingCharacters(in: .whitespaces).isEmpty || isCloning)
                    }

                    if let cloneError {
                        Text(cloneError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func optionRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func createFromScratch() {
        let panel = NSOpenPanel()
        panel.title = "New Project"
        panel.message = "Select or create a folder for your new project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if !isGitRepo(url) {
            initGitRepo(at: url)
        }

        dismiss()
        onOpen(url)
    }

    private func cloneRepo() {
        let trimmed = cloneURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Pick destination
        let panel = NSOpenPanel()
        panel.title = "Clone Destination"
        panel.message = "Choose where to clone the repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let parentDir = panel.url else { return }

        isCloning = true
        cloneError = nil

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["clone", trimmed]
            process.currentDirectoryURL = parentDir

            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()

                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errOutput = String(data: errData, encoding: .utf8) ?? ""

                await MainActor.run {
                    isCloning = false

                    if process.terminationStatus == 0 {
                        // Derive repo folder name from URL
                        let repoName = repoFolderName(from: trimmed)
                        let clonedDir = parentDir.appendingPathComponent(repoName)

                        if FileManager.default.fileExists(atPath: clonedDir.path) {
                            dismiss()
                            onOpen(clonedDir)
                        } else {
                            // Fallback: find the most recently created subdirectory
                            if let found = newestSubdirectory(in: parentDir) {
                                dismiss()
                                onOpen(found)
                            } else {
                                cloneError = "Clone succeeded but could not locate the directory."
                            }
                        }
                    } else {
                        let firstLine = errOutput.components(separatedBy: "\n")
                            .first(where: { !$0.isEmpty }) ?? "Unknown error"
                        cloneError = firstLine
                    }
                }
            } catch {
                await MainActor.run {
                    isCloning = false
                    cloneError = error.localizedDescription
                }
            }
        }
    }

    private func repoFolderName(from urlString: String) -> String {
        var name = URL(string: urlString)?.lastPathComponent ?? urlString
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        return name.isEmpty ? "repo" : name
    }

    private func newestSubdirectory(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        return contents
            .filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return aDate > bDate
            }
            .first
    }

    private func isGitRepo(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private func initGitRepo(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = url
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Previews

#Preview("Project Picker") {
    ProjectPickerView { url in
        print("Opened: \(url)")
    }
    .frame(width: 700, height: 500)
}

#Preview("Main App") {
    ContentView()
}
