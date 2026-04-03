import HoopoeUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar Items

enum SidebarItem: String, Identifiable, CaseIterable {
    case plans = "Plans"
    case newPlan = "New Plan"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .plans: "doc.text"
        case .newPlan: "plus.square"
        }
    }
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

    var selectedSidebarItem: SidebarItem? {
        guard let currentRoute else {
            return nil
        }

        switch currentRoute {
        case .plansHome, .planEditor, .multiModelSynthesis, .refinement, .versionHistory:
            return .plans
        case .planGeneration, .planWizard:
            return .newPlan
        }
    }

    func handleSidebarSelection(_ item: SidebarItem?) {
        guard let item else {
            currentRoute = nil
            backStack.removeAll()
            forwardStack.removeAll()
            return
        }

        switch item {
        case .plans:
            navigate(to: .plansHome)
        case .newPlan:
            navigate(to: .planWizard)
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

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { router.selectedSidebarItem },
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
            PlanWizardPlaceholderView(router: router)
        case let .multiModelSynthesis(planId):
            MultiModelSynthesisPlaceholderView(planId: planId, router: router)
        case let .refinement(planId):
            RefinementPlaceholderView(planId: planId, router: router)
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
    @Binding var selection: SidebarItem?
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
                            .tag(SidebarItem.plans)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                router.navigate(to: .planEditor(planId: plan.id))
                            }
                            .contextMenu {
                                planContextMenu(for: plan)
                            }
                    }
                }
            }

            Section {
                Label("New Plan", systemImage: "plus.square")
                    .tag(SidebarItem.newPlan)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hoopoe")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    router.navigate(to: .planGeneration)
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
        .confirmationDialog(
            "Delete Plan",
            isPresented: Binding(
                get: { planToDelete != nil },
                set: { if !$0 { planToDelete = nil } }
            ),
            titleVisibility: .visible
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
                    if !trimmed.isEmpty {
                        plan.title = trimmed
                        plan.updatedAt = Date()
                        try? planStore.save(plan)
                    }
                    planToRename = nil
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
        try? planStore.delete(plan)
        if wasSelected {
            router.navigate(to: .plansHome)
        }
        planToDelete = nil
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

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "doc.text.magnifyingglass",
            title: "Plans",
            message: "This route now owns the plan-centric flow. Use the buttons below to exercise programmatic navigation."
        ) {
            Button("Open Sample Plan Editor") {
                router.navigate(to: .planEditor(planId: NavigationRouter.samplePlanID))
            }
            .buttonStyle(.borderedProminent)

            Button("Start New Plan Wizard") {
                router.navigate(to: .planWizard)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct PlanWizardPlaceholderView: View {
    let router: NavigationRouter

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "plus.square.dashed",
            title: "New Plan Wizard",
            message: "This placeholder route demonstrates navigation into the creation flow."
        ) {
            Button("Continue to Plan Generation") {
                router.navigate(to: .planGeneration)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct PlanGenerationPlaceholderView: View {
    let router: NavigationRouter

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "wand.and.stars",
            title: "Plan Generation",
            message: "Generation will live on its own route rather than being hard-wired into the sidebar selection state."
        ) {
            Button("Open Generated Plan") {
                router.navigate(to: .planEditor(planId: NavigationRouter.samplePlanID))
            }
            .buttonStyle(.borderedProminent)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.title)
                    .font(.title3.weight(.semibold))

                Text("Selection: \(selectedRange.location):\(selectedRange.length) • \(wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            // Preview mode picker
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
        .padding(.vertical, 12)
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

struct RefinementPlaceholderView: View {
    let planId: UUID
    let router: NavigationRouter

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "arrow.triangle.2.circlepath",
            title: "Refinement",
            message: "This route is ready for the dedicated refinement workflow bead."
        ) {
            Button("Return to Plan Editor") {
                router.navigate(to: .planEditor(planId: planId))
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct VersionHistoryPlaceholderView: View {
    let planId: UUID
    let router: NavigationRouter

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "clock.arrow.circlepath",
            title: "Version History",
            message: "Version browsing now has its own route instead of being entangled with simple sidebar booleans."
        ) {
            Button("Return to Plan Editor") {
                router.navigate(to: .planEditor(planId: planId))
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct MultiModelSynthesisPlaceholderView: View {
    let planId: UUID
    let router: NavigationRouter

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "square.on.square",
            title: "Multi-Model Synthesis",
            message: "This route reserves a clean entry point for the future comparison and synthesis workflow."
        ) {
            Button("Return to Plan Editor") {
                router.navigate(to: .planEditor(planId: planId))
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

// MARK: - Previews

#Preview {
    ContentView()
}
