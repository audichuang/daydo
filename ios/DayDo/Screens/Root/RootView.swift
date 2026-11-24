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
                                    CompactTabContent()

                                    BottomNav(tab: $model.tab, todayDay: model.today.day)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 4)
                                }
                                .accessibilityHidden(model.drawerOpen)
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
                                && ((model.tab == .tasks && model.inlineDetailAllowsSelectionShortcuts)
                                    || (Platform.isMac && model.tab == .calendar && model.inlineDetailSubpageTaskId == nil)),
                            tab: model.tab,
                            scope: model.scope,
                            selectedTaskId: model.selectedTaskId,
                            onMoveSelection: { delta in
                                model.moveTaskSelection(delta: delta)
                            },
                            onSpace: { id in
                                model.toggleSelectedTaskCompletion(id: id)
                            },
                            onEscape: {
                                if model.tab == .calendar {
                                    model.calendarInspectorTaskId = nil
                                } else if model.selectedTaskId != nil {
                                    model.selectedTaskId = nil
                                }
                            },
                            onReturn: { id in
                                model.openTask(id, inlineAvailable: isRegular, focusIfAlreadyInline: true)
                            },
                            onDelete: { id in
                                model.deleteSelectedTask(id: id)
                            },
                            onCalendarCommand: { action in
                                model.triggerCalendarCommand(action)
                            }
                        )
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .menuIndicator(Platform.isMac ? .hidden : .automatic)
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
                .environment(model)
        }
        .sheet(item: $model.composing, onDismiss: {
            model.flushPendingPresentations()
        }) { req in
            ComposerSheet(request: req)
                .environment(model)
        }
        .sheet(item: Binding(get: { model.editingProjectId.map(TaskRef.init) }, set: { model.editingProjectId = $0?.id }), onDismiss: {
            model.flushPendingPresentations()
        }) { ref in
            EditListSheet(projectId: ref.id == "new" ? nil : ref.id)
                .environment(model)
        }
        .sheet(item: Binding(get: { model.sharingProjectId.map(TaskRef.init) }, set: { model.sharingProjectId = $0?.id }), onDismiss: {
            model.flushPendingPresentations()
        }) { ref in
            ShareListSheet(projectId: ref.id)
                .environment(model)
        }
        .sheet(item: $model.invitePrompt, onDismiss: {
            model.flushPendingPresentations()
        }) { prompt in
            InviteConfirmSheet(prompt: prompt)
                .environment(model)
        }
        .sheet(isPresented: $model.showingMeNamePrompt, onDismiss: {
            model.flushPendingPresentations()
        }) {
            MeProfileSheet(mode: .requiredPrompt)
                .environment(model)
        }
        .alert("出了點問題", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .environment(\.isRegularWindow, isRegular)
        .background {
            // Keep `.dark` on the window until SplashOverlay (#0E0F10) finishes dismissing
            // so the status bar stays light-content with no dark flash before the light UI is on screen.
            WindowAppearanceBridge(style: splashRemoved ? model.appearance.userInterfaceStyle : .dark)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rootWidth = $0 }
        .sensoryFeedback(.success, trigger: model.completionHapticTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: model.uncompletionHapticTrigger)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.deleteHapticTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: model.postponeHapticTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: model.restoreHapticTrigger)
        .sensoryFeedback(.selection, trigger: model.tab) { _, _ in model.ready && model.isSignedIn }
    }
}

struct TaskRef: Identifiable { let id: String }

/// Keeps visited main tabs resident so switching between Tasks, Calendar, and
/// Search crossfades without tearing down view trees or repeating SQLite loads.
struct CompactTabContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mountedTabs: Set<MainTab> = []

    var body: some View {
        let activeTab = model.tab
        ZStack {
            if mountedTabs.contains(.tasks) || activeTab == .tasks {
                TaskListScreen(scope: model.scope, isActive: activeTab == .tasks)
                    .opacity(activeTab == .tasks ? 1 : 0)
                    .allowsHitTesting(activeTab == .tasks)
                    .accessibilityElement(children: activeTab == .tasks ? .contain : .ignore)
                    .accessibilityHidden(activeTab != .tasks)
                    .zIndex(activeTab == .tasks ? 1 : 0)
                    .transition(.opacity)
            }
            if mountedTabs.contains(.calendar) || activeTab == .calendar {
                CalendarScreen(isActive: activeTab == .calendar)
                    .opacity(activeTab == .calendar ? 1 : 0)
                    .allowsHitTesting(activeTab == .calendar)
                    .accessibilityElement(children: activeTab == .calendar ? .contain : .ignore)
                    .accessibilityHidden(activeTab != .calendar)
                    .zIndex(activeTab == .calendar ? 1 : 0)
                    .transition(.opacity)
            }
            if mountedTabs.contains(.search) || activeTab == .search {
                SearchScreen(isActive: activeTab == .search)
                    .opacity(activeTab == .search ? 1 : 0)
                    .allowsHitTesting(activeTab == .search)
                    .accessibilityElement(children: activeTab == .search ? .contain : .ignore)
                    .accessibilityHidden(activeTab != .search)
                    .zIndex(activeTab == .search ? 1 : 0)
                    .transition(.opacity)
            }
            if activeTab == .settings {
                SettingsScreen()
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.tabContent(reduceMotion), value: activeTab)
        .onAppear { mountedTabs.insert(activeTab) }
        .onChange(of: activeTab) { _, tab in mountedTabs.insert(tab) }
    }
}

struct SplashOverlay: View {
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

struct SelectionShortcutBridge: UIViewControllerRepresentable {
    var active: Bool
    var tab: MainTab
    var scope: TaskScope
    var selectedTaskId: String?
    var onMoveSelection: (Int) -> Void
    var onSpace: (String) -> Void
    var onEscape: () -> Void
    var onReturn: (String) -> Void
    var onDelete: (String) -> Void
    var onCalendarCommand: (AppModel.CalendarCommandAction) -> Void

    struct CaptureState: Equatable {
        var active: Bool
        var tab: MainTab
        var scope: TaskScope
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
        vc.activeTab = tab
        vc.selectedTaskId = selectedTaskId
        vc.onMoveSelection = onMoveSelection
        vc.onSpace = onSpace
        vc.onEscape = onEscape
        vc.onReturn = onReturn
        vc.onDelete = onDelete
        vc.onCalendarCommand = onCalendarCommand

        let state = CaptureState(active: active, tab: tab, scope: scope, selectedTaskId: selectedTaskId)
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
final class SelectionShortcutViewController: UIViewController {
    var active = false
    var activeTab: MainTab = .tasks
    var selectedTaskId: String?
    var onMoveSelection: ((Int) -> Void)?
    var onSpace: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onReturn: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onCalendarCommand: ((AppModel.CalendarCommandAction) -> Void)?

    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleResponderReturn), name: UITextField.textDidEndEditingNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleResponderReturn), name: UITextView.textDidEndEditingNotification, object: nil)
        if Platform.isMac {
            nc.addObserver(self, selector: #selector(handleResponderReturn), name: UIWindow.didBecomeKeyNotification, object: nil)
        }
    }

    @objc private func handleResponderReturn() {
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
            if activeTab == .calendar && Platform.isMac {
                // Match physical keys, not characters: the user types with Zhuyin, where characters aren't D/W/M/T.
                switch key.keyCode {
                case .keyboardD:
                    onCalendarCommand?(.setMode(.day))
                    handled = true
                case .keyboardW:
                    onCalendarCommand?(.setMode(.week))
                    handled = true
                case .keyboardM:
                    onCalendarCommand?(.setMode(.month))
                    handled = true
                case .keyboardT:
                    onCalendarCommand?(.today)
                    handled = true
                case .keyboardEscape:
                    // Closes the calendar's detail pane; skipped while a text field is
                    // active (guard above), so Esc still cancels Zhuyin composition there.
                    onEscape?()
                    handled = true
                default:
                    break
                }
                continue
            }
            guard activeTab == .tasks else { continue }
            switch key.keyCode {
            case .keyboardUpArrow where Platform.isMac:
                onMoveSelection?(-1)
                handled = true
            case .keyboardDownArrow where Platform.isMac:
                onMoveSelection?(1)
                handled = true
            case .keyboardSpacebar where Platform.isMac:
                if let selectedTaskId {
                    onSpace?(selectedTaskId)
                    handled = true
                }
            case .keyboardEscape where Platform.isMac:
                if selectedTaskId != nil {
                    onEscape?()
                    handled = true
                }
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
                if let selectedTaskId {
                    onDelete?(selectedTaskId)
                    handled = true
                }
            case .keyboardReturnOrEnter:
                if let selectedTaskId {
                    onReturn?(selectedTaskId)
                    handled = true
                }
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

struct WindowAppearanceBridge: UIViewRepresentable {
    var style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.style = style
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.style = style
        AppearanceApplier.applyStyle(style)
        if Platform.isMac, let scene = uiView.window?.windowScene {
            Platform.hideMacWindowTitle(in: scene)
        }
    }

    final class BridgeView: UIView {
        var style: UIUserInterfaceStyle = .dark

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                window.overrideUserInterfaceStyle = style
                if Platform.isMac, let scene = window.windowScene {
                    Platform.hideMacWindowTitle(in: scene)
                }
            }
            AppearanceApplier.applyStyle(style)
        }
    }
}
