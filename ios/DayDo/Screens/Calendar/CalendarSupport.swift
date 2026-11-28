import Observation
import SwiftUI
import DayDoCore

extension CalMode {
    var label: String {
        switch self { case .list: "清單"; case .year: "年"; case .month: "月"; case .week: "週"; case .threeDay: "3日"; case .day: "日" }
    }
    var icon: String {
        switch self {
        case .list: "list.bullet.below.rectangle"
        case .year: "square.grid.3x3"
        case .month: "calendar"
        case .week: "rectangle.split.3x1"
        case .threeDay: "rectangle.split.2x1"
        case .day: "rectangle"
        }
    }
    var macShortcutKey: String? {
        switch self {
        case .month: "M"
        case .week: "W"
        case .day: "D"
        case .list, .year, .threeDay: nil
        }
    }
}

/// High-frequency gesture offsets kept out of `CalendarScreen.body` so dragging
/// does not re-evaluate layouts or diff tasks on every frame.
@MainActor
@Observable
final class CalendarDragState {
    var horizontalOffset: CGFloat = 0
    var collapseY: CGFloat = 0
}

struct HorizontalDragOffsetModifier: ViewModifier {
    var drag: CalendarDragState
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content.offset(x: reduceMotion ? 0 : drag.horizontalOffset)
    }
}

struct CalReload: Hashable {
    var range: ClosedRange<LocalDay>
    var member: String?
    var completed: Bool
    var revision: Int

    var queryKey: CalQueryKey {
        CalQueryKey(range: range, member: member, completed: completed)
    }
}

struct CalActivation: Equatable { var isActive: Bool; var navTrigger: Int }

struct TimeGridScrollKey: Equatable { var days: [LocalDay]; var resetToken: Int }

struct CalQueryKey: Equatable { var range: ClosedRange<LocalDay>; var member: String?; var completed: Bool }

struct CalAgendaContext: Hashable { var day: LocalDay; var member: String?; var project: String?; var completed: Bool }
