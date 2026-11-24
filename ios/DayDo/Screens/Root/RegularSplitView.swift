import SwiftUI
import UIKit
import DayDoCore

struct RegularSplitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var isWide = false
    @State private var calendarPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    /// Mac: the tab that stays visible under the floating search panel.
    @State private var macBehindSearch: MainTab = .tasks

    var body: some View {
        Group {
            if Platform.isMac {
                HStack(spacing: 0) {
                    MacIconRail()
                    macContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.tab == .tasks {
                tasksSplitView
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    nonTaskTabContent
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onChange(of: model.tab) { _, tab in
            if tab != .search { macBehindSearch = tab }
            if tab != .calendar { calendarPath = NavigationPath() }
            if tab != .search { searchPath = NavigationPath() }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 1100
        } action: { wide in
            isWide = wide
            syncColumnVisibility(wide: wide, isTasks: shownTab == .tasks)
        }
        .onChange(of: shownTab == .tasks) { _, isTasks in
            syncColumnVisibility(wide: isWide, isTasks: isTasks)
        }
        .onChange(of: isKanban) { _, newIsKanban in
            if Platform.isMac { return }
            if let next = RegularSplitVisibility.translatedForKanbanToggle(
                current: columnVisibility,
                toKanban: newIsKanban,
                wide: isWide,
                isTasks: model.tab == .tasks
            ) {
                columnVisibility = next
            }
        }
    }

    /// The tab actually on screen: on Mac the search panel floats over the previous tab.
    private var shownTab: MainTab { Platform.isMac && model.tab == .search ? macBehindSearch : model.tab }

    private var isKanban: Bool {
        // The tasks tab also stays visible under the Mac search panel.
        (model.tab == .tasks || (Platform.isMac && model.tab == .search && macBehindSearch == .tasks))
            && model.isKanbanScope(model.scope)
    }

    /// Mac search is a floating panel over the current tab (desktop apps search from a
    /// panel, not a page); the tab underneath keeps its identity while the panel is open.
    private var macContent: some View {
        let shown = shownTab
        return ZStack(alignment: .top) {
            Group {
                if shown == .tasks {
                    tasksSplitView
                } else {
                    tabContent(shown)
                }
            }
            .allowsHitTesting(model.tab != .search)
            .accessibilityHidden(model.tab == .search)

            if model.tab == .search {
                Palette.scrim.ignoresSafeArea()
                    .onTapGesture { model.tab = macBehindSearch }
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
                        Button("關閉搜尋") { model.tab = macBehindSearch }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var tasksSplitView: some View {
        if Platform.isMac {
            // Mac: the list is the main column and the detail a resizable side pane, in both
            // list and kanban mode (one shape, so a half-edited detail survives the switch).
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .toolbar(.hidden, for: .navigationBar)
            } detail: {
                MacTaskColumns(showsPlaceholder: !isKanban)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .navigationSplitViewStyle(.balanced)
            .environment(\.macSidebarToggle) {
                withAnimation(Motion.layout(reduceMotion)) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
        } else if isKanban {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    TaskListScreen(scope: model.scope)
                }
                .navigationSplitViewStyle(.balanced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let taskId = model.selectedTaskId {
                    Rectangle().fill(Palette.separator).frame(width: 1).ignoresSafeArea()
                    TaskDetailContent(taskId: taskId, isInline: true, showCloseButton: true) {
                        model.selectedTaskId = nil
                    }
                    .id(taskId)
                    .frame(width: Platform.isMac ? 380 : 360)
                }
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } content: {
                TaskListScreen(scope: model.scope)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
            } detail: {
                Group {
                    if let taskId = model.selectedTaskId {
                        TaskDetailContent(taskId: taskId, isInline: true) {
                            model.selectedTaskId = nil
                        }
                        .id(taskId)
                    } else {
                        TaskDetailEmptyState()
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(Platform.isMac ? .inline : .automatic)
                .toolbar(Platform.isMac ? .hidden : .automatic, for: .navigationBar)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var nonTaskTabContent: some View { tabContent(model.tab) }

    @ViewBuilder
    private func tabContent(_ tab: MainTab) -> some View {
        switch tab {
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

    private func syncColumnVisibility(wide: Bool, isTasks: Bool) {
        if Platform.isMac && !isTasks { return }
        // Mac tasks are always two columns (sidebar + list/detail), like kanban elsewhere.
        columnVisibility = RegularSplitVisibility.defaultVisibility(wide: wide, isTasks: isTasks, isKanban: Platform.isMac || isKanban)
    }

    private var sidebar: some View {
        DrawerView(close: {}, rowDragging: .constant(false), isSidebar: true)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(
                min: Platform.isMac ? 196 : 230,
                ideal: Platform.isMac ? 220 : 260,
                max: Platform.isMac ? 260 : 300
            )
    }
}

/// Converts `NavigationSplitViewVisibility` between 3-column list mode and 2-column
/// Kanban mode while preserving whether the user currently has the sidebar open.
enum RegularSplitVisibility {
    static func defaultVisibility(
        wide: Bool,
        isTasks: Bool,
        isKanban: Bool
    ) -> NavigationSplitViewVisibility {
        if wide { return .all }
        return (isTasks && !isKanban) ? .doubleColumn : .detailOnly
    }

    /// Returns the translated visibility when toggling Kanban while on the Tasks tab,
    /// or `nil` when leaving the Tasks tab (tab-change sync decides visibility once).
    static func translatedForKanbanToggle(
        current: NavigationSplitViewVisibility,
        toKanban: Bool,
        wide: Bool,
        isTasks: Bool = true
    ) -> NavigationSplitViewVisibility? {
        guard isTasks else { return nil }
        if current == .automatic {
            return defaultVisibility(wide: wide, isTasks: true, isKanban: toKanban)
        }
        if toKanban {
            // 3-column -> 2-column: only `.all` had the sidebar visible.
            return current == .all ? .all : .detailOnly
        } else {
            // 2-column -> 3-column: `.all` or `.doubleColumn` had the sidebar visible.
            return (current == .all || current == .doubleColumn) ? .all : .doubleColumn
        }
    }
}
