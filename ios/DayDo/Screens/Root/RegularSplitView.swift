import SwiftUI
import UIKit
import DayDoCore

struct RegularSplitView: View {
    @Environment(AppModel.self) private var model
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var isWide = false
    @State private var calendarPath = NavigationPath()
    @State private var searchPath = NavigationPath()

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
    private var macContent: some View {
        if model.tab == .tasks {
            tasksSplitView
        } else {
            nonTaskTabContent
        }
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

    @ViewBuilder
    private var nonTaskTabContent: some View {
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

    private func syncColumnVisibility(wide: Bool, isTasks: Bool) {
        if Platform.isMac && !isTasks { return }
        columnVisibility = RegularSplitVisibility.defaultVisibility(wide: wide, isTasks: isTasks, isKanban: isKanban)
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

struct MacIconRail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredId: String?

    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 8) {
            avatarButton
                .padding(.bottom, 6)

            tabButton(
                .tasks,
                label: "任務",
                icon: "checkmark.square",
                selectedIcon: "checkmark.square.fill",
                identifier: "rail.tasks"
            )
            tabButton(
                .calendar,
                label: "日曆",
                icon: "calendar",
                identifier: "rail.calendar"
            )
            tabButton(
                .search,
                label: "搜尋",
                icon: "magnifyingglass",
                identifier: "rail.search"
            )

            Spacer(minLength: 0)

            syncButton

            tabButton(
                .settings,
                label: "設定",
                icon: "gearshape",
                selectedIcon: "gearshape.fill",
                identifier: "rail.settings"
            )
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.separator)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private var avatarButton: some View {
        let hovered = hoveredId == "rail.avatar"
        let selected = model.tab == .settings
        return Button {
            model.tab = .settings
        } label: {
            AvatarView(member: model.me, size: 30, fallbackColor: accent.hex)
                .overlay {
                    Circle()
                        .strokeBorder(selected ? Palette.segmentSelectedText.opacity(0.6) : .clear, lineWidth: 1.5)
                }
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovered ? Palette.pressHighlight : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.press(scale: 0.94, opacity: 0.9))
        .hoverEffect(.highlight)
        .onHover { isHovered in
            hoveredId = isHovered ? "rail.avatar" : (hoveredId == "rail.avatar" ? nil : hoveredId)
        }
        .help("帳號與設定")
        .accessibilityLabel("帳號與設定")
        .accessibilityIdentifier("rail.avatar")
    }

    private func tabButton(
        _ tab: MainTab,
        label: String,
        icon: String,
        selectedIcon: String? = nil,
        identifier: String
    ) -> some View {
        let on = model.tab == tab
        let hovered = hoveredId == identifier
        return Button {
            model.tab = tab
            if tab == .search {
                model.searchFocusTrigger += 1
            }
        } label: {
            Image(systemName: on ? (selectedIcon ?? icon) : icon)
                .font(.system(size: 19, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.segmentSelectedText : (hovered ? Palette.textBody : Palette.textTertiary))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Palette.navSelection : (hovered ? Palette.pressHighlight : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.press(scale: 0.94, opacity: 0.9))
        .hoverEffect(.highlight)
        .onHover { isHovered in
            hoveredId = isHovered ? identifier : (hoveredId == identifier ? nil : hoveredId)
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var syncButton: some View {
        let hovered = hoveredId == "rail.sync"
        let syncing = model.isSyncing
        return Button {
            model.triggerSyncNow()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .regular))
                .symbolEffect(.rotate, isActive: syncing && !reduceMotion)
                .foregroundStyle(hovered ? Palette.textBody : Palette.textTertiary)
                .opacity(syncing ? 0.55 : 1)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovered ? Palette.pressHighlight : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.press(scale: 0.94, opacity: 0.9))
        .hoverEffect(.highlight)
        .onHover { isHovered in
            hoveredId = isHovered ? "rail.sync" : (hoveredId == "rail.sync" ? nil : hoveredId)
        }
        .help(syncing ? "正在同步…" : "立即同步")
        .accessibilityLabel("立即同步")
        .accessibilityIdentifier("rail.sync")
    }
}
