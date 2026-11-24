import Observation
import SwiftUI
import DayDoCore

/// Isolated date grid for 清單 mode: reads `drag.collapseY` without invalidating
/// `CalendarScreen.body`, and isolates `drag.horizontalOffset` via modifier.
struct CalendarDateGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var days: [LocalDay]
    var dayDotColors: [LocalDay: [String]]
    var shownMonth: LocalDay
    var selected: LocalDay
    var today: LocalDay
    @Binding var collapsed: Bool
    var pageSequence: Int
    var pageTransition: AnyTransition
    var isRegular: Bool
    var drag: CalendarDragState
    var onSelectDay: (LocalDay) -> Void
    var onHorizontalEnded: (CGFloat, CGFloat) -> Void

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let rowCount = max(1, days.count / 7)
        let rowH: CGFloat = 50
        let rowSpacing: CGFloat = 2
        let fullGridHeight = CGFloat(rowCount) * rowH + CGFloat(rowCount - 1) * rowSpacing
        let collapsedGridHeight = rowH
        let travel = max(1, fullGridHeight - collapsedGridHeight)
        let restProgress: CGFloat = collapsed ? 0 : 1
        let progress: CGFloat = reduceMotion ? restProgress : min(1, max(0, restProgress + drag.collapseY / travel))
        let visibleGridHeight = collapsedGridHeight + (fullGridHeight - collapsedGridHeight) * progress
        let selectedRow = days.firstIndex(of: selected).map { $0 / 7 } ?? 0
        let gridOffsetY = -CGFloat(selectedRow) * (rowH + rowSpacing) * (1 - progress)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { Text($0).txt(12).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 6)
            ZStack(alignment: .top) {
                LazyVGrid(columns: Self.columns, spacing: rowSpacing) {
                    ForEach(Array(days.enumerated()), id: \.element) { idx, d in
                        let inMonth = d.month == shownMonth.month
                        let cellOpacity = inMonth ? 1.0 : (1.0 - 0.62 * Double(progress))
                        CalendarDayCell(
                            day: d,
                            isSelected: d == selected,
                            isToday: d == today,
                            dotColors: dayDotColors[d] ?? [],
                            reduceMotion: reduceMotion,
                            onTap: { onSelectDay(d) }
                        )
                        .equatable()
                        .opacity(cellOpacity)
                        .allowsHitTesting(progress > 0 || idx / 7 == selectedRow)
                        .accessibilityHidden(progress == 0 && idx / 7 != selectedRow)
                    }
                }
                .offset(y: gridOffsetY)
                .id("list-\(pageSequence)")
                .transition(pageTransition)
            }
            .modifier(HorizontalDragOffsetModifier(drag: drag, reduceMotion: reduceMotion))
            .frame(height: visibleGridHeight, alignment: .top)
            .clipped()

            Button {
                withAnimation(Motion.layout(reduceMotion)) {
                    collapsed.toggle()
                    drag.collapseY = 0
                }
            } label: {
                Capsule().fill(Palette.handle).frame(width: 36, height: 4).frame(maxWidth: .infinity, minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel(collapsed ? "展開整個月份" : "收合成單週")
        }
        .padding(.top, 4)
        .gesture(
            CalendarPanGesture(
                allowLeftEdgeRightward: isRegular,
                allowVertical: { true },
                verticalShouldBegin: { vy in (!collapsed && vy < 0) || (collapsed && vy > 0) },
                onHorizontalChanged: { tx in
                    if !reduceMotion {
                        drag.horizontalOffset = tx * 0.9
                    }
                },
                onHorizontalEnded: onHorizontalEnded,
                onVerticalChanged: { ty in
                    if !reduceMotion {
                        drag.collapseY = ty
                    }
                },
                onVerticalEnded: { ty, vy in
                    withAnimation(Motion.layout(reduceMotion)) {
                        if !collapsed && (ty < -45 || vy < -350) {
                            collapsed = true
                        } else if collapsed && (ty > 45 || vy > 350) {
                            collapsed = false
                        }
                        drag.collapseY = 0
                    }
                }
            )
        )
    }
}

struct CalendarDayCell: View, Equatable {
    @Environment(\.accent) private var accent
    var day: LocalDay
    var isSelected: Bool
    var isToday: Bool
    var dotColors: [String]
    var reduceMotion: Bool
    var onTap: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day
            && lhs.isSelected == rhs.isSelected
            && lhs.isToday == rhs.isToday
            && lhs.dotColors == rhs.dotColors
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .txt(17, isSelected || isToday ? .bold : .medium)
                    .foregroundStyle(isSelected ? accent.onAccent : (isToday ? Palette.todayText(accent: accent) : Palette.textDay))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(isSelected ? accent.color : (isToday ? Palette.todayFill(accent: accent) : .clear)))
                HStack(spacing: 3) {
                    ForEach(dotColors, id: \.self) { c in Circle().fill(Palette.listColor(c)).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press(scale: 0.92, opacity: 0.85))
        .hoverEffect(.highlight)
        .accessibilityLabel(DateText.full(day) + (dotColors.isEmpty ? "" : "，有項目"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
