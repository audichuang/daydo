import SwiftUI
import UIKit
import DayDoCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Namespace private var splashNamespace
    @State private var splashStart = ContinuousClock.now
    @State private var splashDismissing = false
    @State private var splashRemoved = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var edgeDrawerDrag: CGFloat = 0
    @State private var edgeDrawerActive = false
    @State private var rootWidth: CGFloat = 393

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var holdSplash: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-DayDoHoldSplash")
#else
        false
#endif
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Palette.background.ignoresSafeArea()
            if model.ready {
                if model.isSignedIn {
                    Group {
                        if isRegular {
                            RegularSplitView(columnVisibility: $columnVisibility)
                        } else {
                            ZStack(alignment: .bottom) {
                                ZStack(alignment: .bottom) {
                                    Group {
                                        switch model.tab {
                                        case .tasks: TaskListScreen(scope: model.scope).transition(.opacity)
                                        case .calendar: CalendarScreen().transition(.opacity)
                                        case .search: SearchScreen().transition(.opacity)
                                        case .settings: SettingsScreen().transition(.opacity)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .animation(Motion.tabContent(reduceMotion), value: model.tab)

                                    BottomNav(tab: $model.tab, todayDay: model.today.day)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 4)
                                }
                                .gesture(
                                    EdgePanGesture(
                                        isEnabled: {
                                            !model.drawerOpen && !model.hasActiveRootSheet && !model.hasPushedNavigation
                                        },
                                        onChanged: { tx in
                                            edgeDrawerActive = true
                                            edgeDrawerDrag = max(0, tx)
                                        },
                                        onEnded: { tx, vx in
                                            let drawerW = DrawerMetrics.width(for: rootWidth)
                                            let shouldOpen = DrawerMetrics.shouldOpen(translationX: tx, velocityX: vx, drawerWidth: drawerW)
                                            if shouldOpen {
                                                withAnimation(Motion.drawer(reduceMotion)) {
                                                    model.drawerOpen = true
                                                    edgeDrawerDrag = 0
                                                    edgeDrawerActive = false
                                                }
                                            } else {
                                                withAnimation(Motion.drawer(reduceMotion)) {
                                                    edgeDrawerDrag = 0
                                                } completion: {
                                                    if edgeDrawerDrag == 0 && !model.drawerOpen {
                                                        edgeDrawerActive = false
                                                    }
                                                }
                                            }
                                        }
                                    )
                                )

                                DrawerOverlay(open: $model.drawerOpen, edgeDrag: edgeDrawerDrag, isDraggingEdge: edgeDrawerActive)
                            }
                        }
                    }
                    .background {
                        SelectionShortcutBridge(
                            active: splashRemoved
                                && model.isSignedIn
                                && !model.hasActiveRootSheet
                                && model.tab == .tasks
                                && model.inlineDetailAllowsSelectionShortcuts,
                            selectedTaskId: model.selectedTaskId,
                            onReturn: { id in
                                model.openTask(id, inlineAvailable: isRegular, focusIfAlreadyInline: true)
                            },
                            onDelete: { id in
                                model.deleteSelectedTask(id: id)
                            }
                        )
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .opacity(splashDismissing || splashRemoved ? 1 : 0)
                    .scaleEffect(splashDismissing || splashRemoved || reduceMotion ? 1 : 0.98)
                } else {
                    SignInView(
                        logoNamespace: reduceMotion ? nil : splashNamespace,
                        logoRevealed: reduceMotion || splashDismissing || splashRemoved,
                        contentRevealed: splashDismissing || splashRemoved
                    )
                }
            }

            if !splashRemoved {
                SplashOverlay(
                    namespace: reduceMotion ? nil : splashNamespace,
                    isSignedIn: model.isSignedIn,
                    dismissing: splashDismissing,
                    reduceMotion: reduceMotion
                )
                .allowsHitTesting(!splashDismissing)
            }
        }
        .task(id: model.ready) {
            guard model.ready, !splashRemoved, !holdSplash else { return }
            let elapsed = splashStart.duration(to: .now)
            let minDisplay = Duration.seconds(0.35)
            if elapsed < minDisplay {
                try? await Task.sleep(for: minDisplay - elapsed)
            }
            guard !Task.isCancelled else { return }
            let animation = (model.isSignedIn ? Motion.launch : Motion.signIn)(reduceMotion)
            withAnimation(animation) {
                splashDismissing = true
            } completion: {
                splashRemoved = true
            }
        }
        .sheet(item: Binding(get: { model.detailTaskId.map(TaskRef.init) }, set: { model.detailTaskId = $0?.id }), onDismiss: {
            model.flushPendingPresentations()
        }) { ref in
            TaskDetailSheet(taskId: ref.id)
        }
        .sheet(item: $model.composing, onDismiss: {
            model.flushPendingPresentations()
        }) { req in
            ComposerSheet(request: req)
        }
        .sheet(item: Binding(get: { model.editingProjectId.map(TaskRef.init) }, set: { model.editingProjectId = $0?.id }), onDismiss: {
            model.flushPendingPresentations()
        }) { ref in
            EditListSheet(projectId: ref.id == "new" ? nil : ref.id)
        }
        .sheet(item: Binding(get: { model.sharingProjectId.map(TaskRef.init) }, set: { model.sharingProjectId = $0?.id }), onDismiss: {
            model.flushPendingPresentations()
        }) { ref in
            ShareListSheet(projectId: ref.id)
        }
        .sheet(item: $model.invitePrompt, onDismiss: {
            model.flushPendingPresentations()
        }) { prompt in
            InviteConfirmSheet(prompt: prompt)
        }
        .sheet(isPresented: $model.showingJoinInvite, onDismiss: {
            model.flushPendingPresentations()
        }) {
            JoinInviteSheet()
        }
        .sheet(isPresented: $model.showingMeNamePrompt, onDismiss: {
            model.flushPendingPresentations()
        }) {
            MeProfileSheet(mode: .requiredPrompt)
        }
        .alert("出了點問題", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .environment(\.isRegularWindow, isRegular)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rootWidth = $0 }
        .sensoryFeedback(.success, trigger: model.completionHapticTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: model.uncompletionHapticTrigger)
        .sensoryFeedback(.selection, trigger: model.tab) { _, _ in model.ready && model.isSignedIn }
    }
}

struct TaskRef: Identifiable { let id: String }

/// Floating glass navigation: 任務／日曆／搜尋／設定 (62pt high, 30pt from bottom).
struct BottomNav: View {
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var tab: MainTab
    var todayDay: Int
    @Namespace private var selectionNamespace
    @State private var bounceCount: [MainTab: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            item(.tasks, "任務", "checkmark.square", selected: "checkmark.square.fill")
            item(.calendar, "日曆", "calendar")
            item(.search, "搜尋", "magnifyingglass")
            item(.settings, "設定", "gearshape", selected: "gearshape.fill")
        }
        .padding(5)
        .frame(height: 62)
        .glassEffect(.regular.tint(Color(hex: "#242628").opacity(0.6)), in: .capsule)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .animation(Motion.tab(reduceMotion), value: tab)
    }

    func item(_ t: MainTab, _ label: String, _ icon: String, selected: String? = nil) -> some View {
        let on = tab == t
        return Button {
            if tab != t {
                tab = t
            }
            if !reduceMotion {
                bounceCount[t, default: 0] += 1
            }
        } label: {
            Image(systemName: on ? (selected ?? icon) : icon)
                .font(.system(size: 22, weight: on ? .semibold : .regular))
                .symbolEffect(.bounce, value: bounceCount[t, default: 0])
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? accent.text : Palette.textNav)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if on {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .matchedGeometryIfPresent(id: "bottomNavSelection", in: reduceMotion ? nil : selectionNamespace)
                            .transition(.opacity)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.press(scale: 0.95, opacity: 0.9))
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Top toolbar shared by the main screens: drawer button left, a glass
/// capsule of actions right; content scrolls under a fading gradient.
struct ScreenHeader<Center: View, Trailing: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            GlassIconButton(systemName: "line.3.horizontal", label: "開啟清單抽屜") {
                withAnimation(Motion.drawer(reduceMotion)) { model.drawerOpen = true }
            }
            Spacer()
            center
            Spacer()
            HStack(spacing: 0) { trailing }
                .padding(.horizontal, 2)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: Palette.background, location: 0.55), .init(color: Palette.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}

struct HeaderAction: View {
    var systemName: String
    var label: String
    var tint: Color = Palette.text
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 18, weight: .medium)).foregroundStyle(tint)
                .frame(width: 44, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

private struct RegularSplitView: View {
    @Environment(AppModel.self) private var model
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var isWide = false
    @State private var calendarPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    var body: some View {
        Group {
            if model.tab == .tasks {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } content: {
                    TaskListScreen(scope: model.scope)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
                } detail: {
                    if let taskId = model.selectedTaskId {
                        TaskDetailContent(taskId: taskId, isInline: true) {
                            model.selectedTaskId = nil
                        }
                        .id(taskId)
                    } else {
                        TaskDetailEmptyState()
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    switch model.tab {
                    case .calendar:
                        NavigationStack(path: $calendarPath) {
                            CalendarScreen()
                        }
                    case .search:
                        NavigationStack(path: $searchPath) {
                            SearchScreen()
                        }
                    case .settings:
                        SettingsScreen()
                    case .tasks:
                        EmptyView()
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onChange(of: model.tab) { _, tab in
            if tab != .calendar { calendarPath = NavigationPath() }
            if tab != .search { searchPath = NavigationPath() }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 1100
        } action: { wide in
            isWide = wide
            syncColumnVisibility(wide: wide, isTasks: model.tab == .tasks)
        }
        .onChange(of: model.tab == .tasks) { _, isTasks in
            syncColumnVisibility(wide: isWide, isTasks: isTasks)
        }
    }

    private func syncColumnVisibility(wide: Bool, isTasks: Bool) {
        if wide {
            columnVisibility = .all
        } else {
            columnVisibility = isTasks ? .doubleColumn : .detailOnly
        }
    }

    private var sidebar: some View {
        DrawerView(close: {}, rowDragging: .constant(false), isSidebar: true)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
    }
}

private struct SplashOverlay: View {
    var namespace: Namespace.ID?
    var isSignedIn: Bool
    var dismissing: Bool
    var reduceMotion: Bool

    var body: some View {
        ZStack {
            if isSignedIn || reduceMotion {
                Color("LaunchBackground")
                    .ignoresSafeArea()
                    .opacity(dismissing ? 0 : 1)
            } else if !dismissing {
                Color("LaunchBackground")
                    .ignoresSafeArea()
                    .transition(.identity)
            }

            if isSignedIn || reduceMotion || !dismissing {
                Image("LaunchLogo")
                    .resizable()
                    .frame(width: 120, height: 120)
                    .matchedGeometryIfPresent(id: "launchLogo", in: namespace)
                    .scaleEffect(!reduceMotion && dismissing && isSignedIn ? 1.15 : 1)
                    .opacity(isSignedIn || reduceMotion ? (dismissing ? 0 : 1) : 1)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("splash.overlay")
    }
}

extension View {
    @ViewBuilder
    func matchedGeometryIfPresent<ID: Hashable>(id: ID, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}

private struct SelectionShortcutBridge: UIViewControllerRepresentable {
    var active: Bool
    var selectedTaskId: String?
    var onReturn: (String) -> Void
    var onDelete: (String) -> Void

    struct CaptureState: Equatable {
        var active: Bool
        var selectedTaskId: String?
    }

    final class Coordinator {
        var lastState: CaptureState?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> SelectionShortcutViewController {
        SelectionShortcutViewController()
    }

    func updateUIViewController(_ vc: SelectionShortcutViewController, context: Context) {
        vc.active = active
        vc.selectedTaskId = selectedTaskId
        vc.onReturn = onReturn
        vc.onDelete = onDelete

        let state = CaptureState(active: active, selectedTaskId: selectedTaskId)
        guard state != context.coordinator.lastState else { return }
        context.coordinator.lastState = state
        if active {
            DispatchQueue.main.async {
                vc.claimResponderIfNeeded()
            }
        } else if vc.isFirstResponder {
            DispatchQueue.main.async {
                vc.resignFirstResponder()
            }
        }
    }
}

@MainActor
private final class SelectionShortcutViewController: UIViewController {
    var active = false
    var selectedTaskId: String?
    var onReturn: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleTextDidEndEditing), name: UITextField.textDidEndEditingNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleTextDidEndEditing), name: UITextView.textDidEndEditingNotification, object: nil)
    }

    @objc private func handleTextDidEndEditing() {
        DispatchQueue.main.async { [weak self] in
            self?.claimResponderIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.claimResponderIfNeeded()
        }
    }

    func claimResponderIfNeeded() {
        guard active,
              let window = view.window,
              window.isKeyWindow,
              !Self.hasActiveTextInput(in: window) else { return }
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard active,
              let selectedTaskId,
              let window = view.window,
              window.isKeyWindow,
              !Self.hasActiveTextInput(in: window) else {
            super.pressesBegan(presses, with: event)
            return
        }
        var handled = false
        for press in presses {
            guard let key = press.key,
                  key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty else { continue }
            switch key.keyCode {
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
                onDelete?(selectedTaskId)
                handled = true
            case .keyboardReturnOrEnter:
                onReturn?(selectedTaskId)
                handled = true
            default:
                break
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    private static func hasActiveTextInput(in view: UIView) -> Bool {
        if (view is UITextField || view is UITextView) && view.isFirstResponder { return true }
        return view.subviews.contains { hasActiveTextInput(in: $0) }
    }
}
