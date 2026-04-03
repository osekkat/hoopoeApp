import Observation
import SwiftUI

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

struct ContentView: View {
    @State private var router = NavigationRouter()
    @State private var inspectorIsVisible = true

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { router.selectedSidebarItem },
            set: { router.handleSidebarSelection($0) }
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: sidebarSelection)
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
            PlanEditorRouteView(planId: planId, router: router)
        case .planGeneration:
            PlanGenerationPlaceholderView(router: router)
        case .planWizard:
            PlanWizardPlaceholderView(router: router)
        case let .multiModelSynthesis(planId):
            MultiModelSynthesisPlaceholderView(planId: planId, router: router)
        case let .refinement(planId):
            RefinementPlaceholderView(planId: planId, router: router)
        case let .versionHistory(planId):
            VersionHistoryPlaceholderView(planId: planId, router: router)
        case nil:
            NoSelectionView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Project") {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item as SidebarItem?)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hoopoe")
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
    let planId: UUID
    let router: NavigationRouter

    var body: some View {
        RoutePlaceholderCard(
            systemImage: "square.and.pencil",
            title: "Plan Editor",
            message: "Programmatic child navigation for refinement, synthesis, and version history hangs off the editor route."
        ) {
            Text(planId.uuidString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("Refinement") {
                    router.navigate(to: .refinement(planId: planId))
                }
                .buttonStyle(.borderedProminent)

                Button("Version History") {
                    router.navigate(to: .versionHistory(planId: planId))
                }
                .buttonStyle(.bordered)

                Button("Synthesis") {
                    router.navigate(to: .multiModelSynthesis(planId: planId))
                }
                .buttonStyle(.bordered)
            }
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
