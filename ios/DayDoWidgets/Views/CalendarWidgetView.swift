import SwiftUI
import WidgetKit
import DayDoCore

struct CalendarWidgetView: View {
    var data: WidgetCalendarData?
    var family: WidgetFamily
    var accent: WidgetAccent

    private var isExtraLargePortrait: Bool {
        if #available(iOS 27.0, *) {
            return family == .systemExtraLargePortrait
        }
        return false
    }

    var body: some View {
        Group {
            if let data {
                if isExtraLargePortrait {
                    portraitXL(data)
                } else {
                    switch family {
                    case .systemSmall:
                        small(data)
                    case .systemMedium:
                        wide(
                            data,
                            showMonthTitle: false,
                            weekCount: data.twoWeekLayout.weeks.count,
                            capLanes: 2,
                            layoutForLanes: { data.twoWeekLayout(maxLanes: $0) }
                        )
                    case .systemLarge, .systemExtraLarge:
                        wide(
                            data,
                            showMonthTitle: true,
                            weekCount: data.monthLayout.weeks.count,
                            capLanes: 3,
                            layoutForLanes: { data.monthLayout(maxLanes: $0) }
                        )
                    default:
                        small(data)
                    }
                }
            } else {
                WidgetUnavailableView(
                    title: "日曆",
                    message: "開啟 DayDo 以顯示日曆",
                    accent: accent
                )
            }
        }
        .widgetPadding(for: family)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.calendar(nil).url)
    }

    private func small(_ data: WidgetCalendarData) -> some View {
        let weeks = stride(from: 0, to: data.miniDays.count, by: 7).map { idx in
            Array(data.miniDays[idx..<min(idx + 7, data.miniDays.count)])
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(data.month.month) 月")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(accent.text)
                .padding(.leading, 2)

            weekdayHeader

            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { wIdx, week in
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { day in
                            let inMonth = day.month == data.month.month
                            let isToday = day == data.today
                            let hasEvent = inMonth && data.daysWithEvents.contains(day)

                            VStack(spacing: 1) {
                                Text("\(day.day)")
                                    .font(.system(size: 10, weight: isToday ? .bold : .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(isToday ? accent.text : WidgetPalette.textDay)
                                    .frame(width: 17, height: 17)
                                    .overlay {
                                        if isToday {
                                            Circle().strokeBorder(accent.text, lineWidth: 1.2)
                                        }
                                    }
                                Circle()
                                    .fill(hasEvent ? WidgetPalette.textSecondary : .clear)
                                    .frame(width: 3, height: 3)
                            }
                            .frame(maxWidth: .infinity)
                            .opacity(inMonth ? 1 : 0.38)
                        }
                    }
                    if wIdx < weeks.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func wide(
        _ data: WidgetCalendarData,
        showMonthTitle: Bool,
        weekCount: Int,
        capLanes: Int,
        layoutForLanes: @escaping (Int) -> MonthLayout
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showMonthTitle {
                Text("\(String(data.month.year)) 年 \(data.month.month) 月")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent.text)
                    .padding(.leading, 2)
                    .padding(.bottom, 4)
            }

            weekdayHeader
                .padding(.bottom, 2)

            GeometryReader { geo in
                let count = max(1, weekCount)
                let rowHeight = geo.size.height / CGFloat(count)
                let maxLanes = Self.fittingLanes(rowHeight: rowHeight, cap: capLanes)
                let layout = layoutForLanes(maxLanes)

                VStack(spacing: 0) {
                    ForEach(Array(layout.weeks.enumerated()), id: \.offset) { _, week in
                        WidgetCalendarWeekView(
                            week: week,
                            month: data.month,
                            today: data.today,
                            maxLanes: maxLanes,
                            projectColorsById: data.projectColorsById,
                            accent: accent
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func fittingLanes(rowHeight: CGFloat, cap: Int) -> Int {
        let headerH: CGFloat = 18
        let laneStep: CGFloat = 12
        let moreH: CGFloat = 11
        let bottomMargin: CGFloat = 1
        let availableForLanes = rowHeight - headerH - moreH - bottomMargin
        let count = Int(floor(availableForLanes / laneStep))
        return min(cap, max(1, count))
    }

    private func portraitXL(_ data: WidgetCalendarData) -> some View {
        let weeks = stride(from: 0, to: data.miniDays.count, by: 7).map { idx in
            Array(data.miniDays[idx..<min(idx + 7, data.miniDays.count)])
        }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(data.month.month) 月")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent.text)
                    .padding(.leading, 2)

                weekdayHeader

                VStack(spacing: 2) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { day in
                                let inMonth = day.month == data.month.month
                                let isToday = day == data.today
                                let hasEvent = inMonth && data.daysWithEvents.contains(day)

                                Link(destination: WidgetDeepLink.calendar(day).url) {
                                    VStack(spacing: 1) {
                                        Text("\(day.day)")
                                            .font(.system(size: 11, weight: isToday ? .bold : .medium))
                                            .monospacedDigit()
                                            .foregroundStyle(isToday ? accent.onAccent : WidgetPalette.textDay)
                                            .frame(width: 20, height: 17)
                                            .background(
                                                Capsule()
                                                    .fill(isToday ? accent.color : .clear)
                                            )
                                        Circle()
                                            .fill(hasEvent ? WidgetPalette.textSecondary : .clear)
                                            .frame(width: 3.5, height: 3.5)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .opacity(inMonth ? 1 : 0.38)
                                }
                            }
                        }
                    }
                }
            }

            Rectangle()
                .fill(WidgetPalette.divider)
                .frame(height: 1)
                .padding(.vertical, 6)

            GeometryReader { geo in
                let limits = Self.allocateAgendaLimits(days: data.upcomingDays, availableHeight: geo.size.height)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.upcomingDays.enumerated()), id: \.element.id) { idx, dayAgenda in
                        let isToday = idx == 0
                        let limit = idx < limits.count ? limits[idx] : 0
                        let visible = Array(dayAgenda.events.prefix(limit))
                        let overflow = max(0, dayAgenda.events.count - visible.count)

                        VStack(alignment: .leading, spacing: 3) {
                            Link(destination: WidgetDeepLink.calendar(dayAgenda.day).url) {
                                Text(Self.agendaHeaderText(for: dayAgenda.day, offset: idx))
                                    .font(.system(size: isToday ? 13 : 12, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(isToday ? accent.text : WidgetPalette.textSecondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if dayAgenda.events.isEmpty {
                                Text("—")
                                    .font(.system(size: 11))
                                    .foregroundStyle(WidgetPalette.textMuted)
                            } else {
                                ForEach(visible) { event in
                                    WidgetAgendaEventRow(
                                        event: event,
                                        titleSize: isToday ? 13 : 12,
                                        timeSize: isToday ? 12 : 11.5
                                    )
                                }
                                if overflow > 0 {
                                    Text("+\(overflow)")
                                        .font(.system(size: 11, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(WidgetPalette.textMuted)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.top, idx == 0 ? 0 : 7)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func agendaHeaderText(for day: LocalDay, offset: Int) -> String {
        let wd = "週\(LocalDay.weekdaySymbols[day.weekday])"
        switch offset {
        case 0: return "今天 · \(wd) \(day.day)"
        case 1: return "明天 · \(wd) \(day.day)"
        default: return "\(wd) \(day.day)"
        }
    }

    private static func allocateAgendaLimits(
        days: [WidgetCalendarData.DayAgenda],
        availableHeight: CGFloat
    ) -> [Int] {
        guard !days.isEmpty else { return [] }
        let rowSpacing: CGFloat = 3
        let sectionGap: CGFloat = 7
        let moreH: CGFloat = 14

        func sectionHeight(index: Int, shown: Int, total: Int) -> CGFloat {
            let headerH: CGFloat = index == 0 ? 17 : 15.5
            let rowH: CGFloat = index == 0 ? 17 : 15.5
            let topGap: CGFloat = index == 0 ? 0 : sectionGap
            if total == 0 {
                return topGap + headerH + rowSpacing + 14
            }
            let hasOverflow = shown < total
            let rows = CGFloat(shown) * rowH + CGFloat(shown) * rowSpacing
            let more = hasOverflow ? (moreH + rowSpacing) : 0
            return topGap + headerH + rows + more
        }

        func totalHeight(for counts: [Int]) -> CGFloat {
            counts.enumerated().reduce(0) { acc, pair in
                acc + sectionHeight(index: pair.offset, shown: pair.element, total: days[pair.offset].events.count)
            }
        }

        let full = days.map(\.events.count)
        if totalHeight(for: full) <= availableHeight {
            return full
        }

        var counts = days.map { $0.events.isEmpty ? 0 : 1 }
        while totalHeight(for: counts) > availableHeight, let idx = counts.lastIndex(where: { $0 > 0 }) {
            counts[idx] -= 1
        }

        var grew = true
        while grew {
            grew = false
            for idx in days.indices where counts[idx] < days[idx].events.count {
                var candidate = counts
                candidate[idx] += 1
                if totalHeight(for: candidate) <= availableHeight {
                    counts = candidate
                    grew = true
                }
            }
        }
        return counts
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(LocalDay.weekdaySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.system(size: 9))
                    .foregroundStyle(WidgetPalette.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct WidgetCalendarWeekView: View {
    var week: MonthLayout.Week
    var month: LocalDay
    var today: LocalDay
    var maxLanes: Int
    var projectColorsById: [String: String]
    var accent: WidgetAccent

    var body: some View {
        let headerH: CGFloat = 18
        let laneStep: CGFloat = 12
        let barH: CGFloat = 11

        GeometryReader { geo in
            let colW = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                        let inMonth = day.month == month.month
                        let isToday = day == today
                        Link(destination: WidgetDeepLink.calendar(day).url) {
                            Text("\(day.day)")
                                .font(.system(size: 10, weight: isToday ? .bold : .medium))
                                .monospacedDigit()
                                .foregroundStyle(isToday ? accent.onAccent : WidgetPalette.textDay)
                                .padding(.horizontal, 2)
                                .frame(minWidth: 15)
                                .frame(height: 15)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isToday ? accent.color : .clear)
                                )
                                .padding(.leading, 2)
                                .padding(.top, 2)
                                .frame(width: colW, height: geo.size.height, alignment: .topLeading)
                                .opacity(inMonth ? 1 : 0.38)
                        }
                    }
                }

                ForEach(Array(week.bars.enumerated()), id: \.offset) { _, bar in
                    let done = bar.task.isCompleted
                    let hex = projectColorsById[bar.task.projectId]
                    let bg = done ? WidgetPalette.doneBackground : WidgetPalette.listColor(hex).opacity(0.22)
                    let fg = done ? WidgetPalette.doneText : WidgetPalette.tintedListText(hex)
                    let barW = max(8, colW * CGFloat(bar.endColumn - bar.startColumn + 1) - 2)
                    let barX = colW * CGFloat(bar.startColumn) + 1
                    let barY = headerH + CGFloat(bar.lane) * laneStep

                    Link(destination: WidgetDeepLink.task(bar.task.id).url) {
                        Text((bar.continues ? "‹ " : "") + bar.task.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(fg)
                            .lineLimit(1)
                            .padding(.horizontal, 2)
                            .frame(width: barW, height: barH, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(bg)
                            )
                    }
                    .offset(x: barX, y: barY)
                }

                ForEach(week.overflow.keys.sorted(), id: \.self) { col in
                    if let count = week.overflow[col] {
                        let moreY = headerH + CGFloat(maxLanes) * laneStep
                        Text("＋\(count)")
                            .font(.system(size: 8.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.textSecondary)
                            .lineLimit(1)
                            .frame(width: colW - 4, height: 11, alignment: .leading)
                            .offset(x: colW * CGFloat(col) + 3, y: moreY)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WidgetPalette.divider)
                .frame(height: 1)
        }
    }
}
