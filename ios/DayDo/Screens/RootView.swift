import SwiftUI
import DayDoCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var splashNamespace
    @State private var splashStart = ContinuousClock.now
    @State private var splashDismissing = false
    @State private var splashRemoved = false

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
                    ZStack(alignment: .bottom) {
                        Group {
                            switch model.tab {
                            case .tasks: TaskListScreen(scope: model.scope)
                            case .calendar: CalendarScreen()
                            case .search: SearchScreen()
                            case .settings: SettingsScreen()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        BottomNav(tab: $model.tab, todayDay: model.today.day)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)

                        DrawerOverlay(open: $model.drawerOpen)
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
            let animation: Animation = reduceMotion
                ? .easeOut(duration: 0.25)
                : (model.isSignedIn ? .easeOut(duration: 0.45) : .spring(duration: 0.45, bounce: 0.1))
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
    }
}

struct TaskRef: Identifiable { let id: String }

/// Floating glass navigation: 任務／日曆／搜尋／設定 (62pt high, 30pt from bottom).
struct BottomNav: View {
    @Environment(\.accent) private var accent
    @Binding var tab: MainTab
    var todayDay: Int

    var body: some View {
        HStack(spacing: 2) {
            item(.tasks, "任務", "checkmark.square")
            item(.calendar, "日曆", "calendar")
            item(.search, "搜尋", "magnifyingglass")
            item(.settings, "設定", "gearshape")
        }
        .padding(5)
        .frame(height: 62)
        .glassEffect(.regular.tint(Color(hex: "#242628").opacity(0.6)), in: .capsule)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }

    func item(_ t: MainTab, _ label: String, _ icon: String) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular))
                Text(label).font(.system(size: 11, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? accent.text : Palette.textNav)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(on ? Color.white.opacity(0.08) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Top toolbar shared by the main screens: drawer button left, a glass
/// capsule of actions right; content scrolls under a fading gradient.
struct ScreenHeader<Center: View, Trailing: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            GlassIconButton(systemName: "line.3.horizontal", label: "開啟清單抽屜") {
                withAnimation(.snappy) { model.drawerOpen = true }
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
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
