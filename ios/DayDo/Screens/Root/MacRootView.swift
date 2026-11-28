import SwiftUI
import DayDoCore

/// Mac shell: icon rail, tasks as list + resizable detail, and search as a floating panel.
/// iPad lives in `RegularSplitView`; the two share screens, not layout code.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var isWide = false
    @State private var calendarPath = NavigationPath()
    /// The tab that stays visible under the floating search panel.
    @State private var behindSearch: MainTab = .tasks

    var body: some View {
        HStack(spacing: 0) {
            MacIconRail()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.tab) { _, tab in
            if tab != .search { behindSearch = tab }
            if tab != .calendar { calendarPath = NavigationPath() }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 1100
        } action: { wide in
            isWide = wide
            syncColumnVisibility()
        }
        .onChange(of: shownTab == .tasks) { _, _ in
            syncColumnVisibility()
        }
    }

    /// The tab actually on screen: the search panel floats over the previous tab.
    private var shownTab: MainTab { model.tab == .search ? behindSearch : model.tab }

    /// Desktop apps search from a panel, not a page; the tab underneath keeps its
    /// identity while the panel is open.
    private var content: some View {
        let shown = shownTab
        return ZStack(alignment: .top) {
            Group {
                switch shown {
                case .tasks: tasksColumns
                case .calendar: NavigationStack(path: $calendarPath) { CalendarScreen() }
                case .settings: SettingsScreen()
                case .search: EmptyView()
                }
            }
            .allowsHitTesting(model.tab != .search)
            .accessibilityHidden(model.tab == .search)

            if model.tab == .search {
                Palette.scrim.ignoresSafeArea()
                    .onTapGesture { model.tab = behindSearch }
                    .accessibilityLabel("關閉搜尋")
                    .accessibilityAddTraits(.isButton)
                SearchScreen()
                    .frame(width: 640)
                    .frame(maxHeight: 560)
                    .background(Palette.background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1)
                    }
                    .shadow(color: Palette.navShadow, radius: 24, y: 8)
                    .padding(.top, 72)
                    .background {
                        // Esc closes the panel even while the search field has focus.
                        Button("關閉搜尋") { model.tab = behindSearch }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
                    .transition(.opacity)
            }
        }
    }

    /// The list is the main column and the detail a resizable side pane, in both list and
    /// kanban mode (one shape, so a half-edited detail survives the switch).
    private var tasksColumns: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DrawerView(close: {}, rowDragging: .constant(false), isSidebar: true)
                .navigationBarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(min: 196, ideal: 220, max: 260)
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            MacTaskColumns(showsPlaceholder: !model.isKanbanScope(model.scope))
                .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.macSidebarToggle) {
            withAnimation(Motion.layout(reduceMotion)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
    }

    /// Tasks are always two columns (sidebar + list/detail); the sidebar folds away when narrow.
    private func syncColumnVisibility() {
        guard shownTab == .tasks else { return }
        columnVisibility = RegularSplitVisibility.defaultVisibility(wide: isWide, isTasks: true, isKanban: true)
    }
}
