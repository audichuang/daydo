import SwiftUI
import DayDoCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Palette.background.ignoresSafeArea()
            if model.ready {
            Group {
                switch model.tab {
                case .tasks: TaskListScreen(scope: model.scope)
                case .calendar: CalendarScreen()
                case .shared: SharedScreen()
                case .search: SearchScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BottomNav(tab: $model.tab, todayDay: model.today.day)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            DrawerOverlay(open: $model.drawerOpen)
            }
        }
        .sheet(item: Binding(get: { model.detailTaskId.map(TaskRef.init) }, set: { model.detailTaskId = $0?.id }), onDismiss: {
            if let next = model.pendingDetailTaskId {
                model.pendingDetailTaskId = nil
                model.detailTaskId = next
            }
        }) { ref in
            TaskDetailSheet(taskId: ref.id)
        }
        .sheet(item: $model.composing) { req in
            ComposerSheet(request: req)
        }
        .sheet(item: Binding(get: { model.editingProjectId.map(TaskRef.init) }, set: { model.editingProjectId = $0?.id })) { ref in
            EditListSheet(projectId: ref.id == "new" ? nil : ref.id)
        }
        .sheet(isPresented: $model.showSettings) { SettingsSheet() }
        .alert("出了點問題", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct TaskRef: Identifiable { let id: String }

/// Floating glass navigation: 任務／日曆／共享／搜尋 (62pt high, 30pt from bottom).
struct BottomNav: View {
    @Environment(\.accent) private var accent
    @Binding var tab: MainTab
    var todayDay: Int

    var body: some View {
        HStack(spacing: 2) {
            item(.tasks, "任務", "checkmark.square")
            item(.calendar, "日曆", "calendar")
            item(.shared, "共享", "person.2")
            item(.search, "搜尋", "magnifyingglass")
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
