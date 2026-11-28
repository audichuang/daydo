import SwiftUI
import UIKit
import DayDoCore

/// iPad shell (regular width). The Mac shell is `MacRootView`; keep Mac branches out of here.
struct RegularSplitView: View {
    @Environment(AppModel.self) private var model
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var isWide = false
    @State private var calendarPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    var body: some View {
        Group {
            if model.tab == .tasks {
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
        .onChange(of: isKanban) { _, newIsKanban in
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

    private var isKanban: Bool {
        model.tab == .tasks && model.isKanbanScope(model.scope)
    }

    @ViewBuilder
    private var tasksSplitView: some View {
        if isKanban {
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
                    .frame(width: 360)
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
        columnVisibility = RegularSplitVisibility.defaultVisibility(wide: wide, isTasks: isTasks, isKanban: isKanban)
    }

    private var sidebar: some View {
        DrawerView(close: {}, rowDragging: .constant(false), isSidebar: true)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
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
