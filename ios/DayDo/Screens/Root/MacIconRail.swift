import SwiftUI
import UIKit
import DayDoCore

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
