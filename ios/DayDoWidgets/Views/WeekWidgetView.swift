import SwiftUI
import WidgetKit
import DayDoCore

struct WeekWidgetView: View {
    @Environment(\.legibilityWeight) private var legibilityWeight

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
                    case .systemMedium:
                        medium(data)
                    case .systemLarge:
                        large(data)
                    case .systemExtraLarge:
                        extraLarge(data)
                    default:
                        medium(data)
                    }
                }
            } else {
                WidgetUnavailableView(
                    title: "本週",
                    message: "開啟 DayDo 以顯示本週行程",
                    accent: accent
                )
            }
        }
        .widgetPadding(for: family)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.calendar(nil).url)
    }

    // MARK: - M1 (systemMedium)

    private func medium(_ data: WidgetCalendarData) -> some View {
        let todayEvents = Array(data.todayEvents.prefix(2))
        let extra = max(0, data.todayEvents.count - todayEvents.count)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                ForEach(data.weekDays) { dayAgenda in
                    let isToday = dayAgenda.day == data.today
                    let isPast = dayAgenda.day < data.today
                    let hasEvent = !dayAgenda.events.isEmpty
                    Link(destination: WidgetDeepLink.calendar(dayAgenda.day).url) {
                        VStack(spacing: 2) {
                            Text(LocalDay.weekdaySymbols[dayAgenda.day.weekday])
                                .font(.system(size: 10))
                                .foregroundStyle(WidgetPalette.textSecondary)
                            Text("\(dayAgenda.day.day)")
                                .font(.system(size: 13, weight: isToday ? .bold : .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isToday ? accent.onAccent : WidgetPalette.textDay)
                                .padding(.horizontal, isToday ? 5 : 0)
                                .frame(minWidth: 20, minHeight: 17)
                                .background(
                                    Capsule()
                                        .fill(isToday ? accent.color : .clear)
                                )
                            Circle()
                                .fill(hasEvent ? WidgetPalette.textSecondary : .clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(isPast ? 0.5 : 1)
                    }
                }
            }

            Rectangle()
                .fill(WidgetPalette.divider)
                .frame(height: 1)

            if todayEvents.isEmpty {
                Text("今天沒有行程")
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetPalette.textMuted)
                Spacer(minLength: 0)
            } else if extra == 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(todayEvents) { event in
                        WidgetAgendaEventRow(event: event, titleSize: 12, timeSize: 11.5)
                    }
                }
                Spacer(minLength: 0)
            } else {
                // Place "+N" on its own line when height allows (iPhone), or inline on the
                // second row when height is compact (iPad mini landscape 253x117).
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(todayEvents) { event in
                            WidgetAgendaEventRow(event: event, titleSize: 12, timeSize: 11.5)
                        }
                        WidgetOverflowLink(count: extra, day: data.today)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 3) {
                        if let first = todayEvents.first {
                            WidgetAgendaEventRow(event: first, titleSize: 12, timeSize: 11.5)
                        }
                        if todayEvents.count > 1 {
                            HStack(spacing: 6) {
                                WidgetAgendaEventRow(event: todayEvents[1], titleSize: 12, timeSize: 11.5)
                                WidgetOverflowLink(count: extra, day: data.today)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - L1 (systemLarge)

    private func large(_ data: WidgetCalendarData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            weekHeader(data)
                .padding(.bottom, 4)

            ForEach(data.weekDays) { dayAgenda in
                let isToday = dayAgenda.day == data.today
                let isPast = dayAgenda.day < data.today
                let visible = Array(dayAgenda.events.prefix(2))
                let extra = max(0, dayAgenda.events.count - visible.count)

                HStack(spacing: 6) {
                    Link(destination: WidgetDeepLink.calendar(dayAgenda.day).url) {
                        VStack(spacing: 0) {
                            Text(LocalDay.weekdaySymbols[dayAgenda.day.weekday])
                                .font(.system(size: 9.5))
                                .foregroundStyle(WidgetPalette.textSecondary)
                            Text("\(dayAgenda.day.day)")
                                .font(.system(size: 12.5, weight: isToday ? .bold : .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isToday ? accent.onAccent : WidgetPalette.textDay)
                                .padding(.horizontal, isToday ? 5 : 0)
                                .frame(minWidth: 20, minHeight: 15)
                                .background(
                                    Capsule()
                                        .fill(isToday ? accent.color : .clear)
                                )
                        }
                        .frame(width: 30)
                    }

                    if visible.isEmpty {
                        Link(destination: WidgetDeepLink.calendar(dayAgenda.day).url) {
                            Text("—")
                                .font(.system(size: 11))
                                .foregroundStyle(WidgetPalette.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        HStack(spacing: 4) {
                            ForEach(visible) { event in
                                let done = event.task.isCompleted
                                let bg = done ? WidgetPalette.doneBackground : WidgetPalette.listColor(event.projectColorHex).opacity(0.22)
                                let fg = done ? WidgetPalette.doneText : WidgetPalette.tintedListText(event.projectColorHex)
                                Link(destination: WidgetDeepLink.task(event.task.id).url) {
                                    Text(event.task.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(fg)
                                        .lineLimit(1)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(bg)
                                        )
                                }
                            }
                            if extra > 0 {
                                WidgetOverflowLink(count: extra, day: dayAgenda.day)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(WidgetPalette.divider)
                        .frame(height: 1)
                }
                .opacity(isPast ? 0.5 : 1)
            }
        }
    }

    // MARK: - X3 (systemExtraLarge)

    private func extraLarge(_ data: WidgetCalendarData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            weekHeader(data)

            GeometryReader { geo in
                let colSpacing: CGFloat = 4
                let colPadding: CGFloat = 3
                let headerH: CGFloat = 20
                let itemGap: CGFloat = 4
                let colW = max(20, (geo.size.width - colSpacing * 6) / 7)

                HStack(alignment: .top, spacing: colSpacing) {
                    ForEach(data.weekDays) { dayAgenda in
                        let isToday = dayAgenda.day == data.today
                        let isPast = dayAgenda.day < data.today

                        VStack(alignment: .leading, spacing: itemGap) {
                            Link(destination: WidgetDeepLink.calendar(dayAgenda.day).url) {
                                HStack(spacing: 3) {
                                    Text(LocalDay.weekdaySymbols[dayAgenda.day.weekday])
                                        .font(.system(size: 11))
                                        .foregroundStyle(WidgetPalette.textSecondary)
                                    Text("\(dayAgenda.day.day)")
                                        .font(.system(size: 13.5, weight: .bold))
                                        .monospacedDigit()
                                        .foregroundStyle(isToday ? accent.onAccent : WidgetPalette.textDay)
                                        .padding(.horizontal, isToday ? 5 : 0)
                                        .frame(minHeight: 18)
                                        .background(
                                            Capsule()
                                                .fill(isToday ? accent.color : .clear)
                                        )
                                }
                                .frame(maxWidth: .infinity, minHeight: headerH, maxHeight: headerH, alignment: .leading)
                            }

                            if !dayAgenda.events.isEmpty {
                                // Measured by SwiftUI directly so Bold Text and wrapping never clip the last row or +N.
                                FittingColumnList(
                                    totalCount: dayAgenda.events.count,
                                    maxShown: min(dayAgenda.events.count, 12),
                                    gap: itemGap,
                                    item: { idx in
                                        columnEventRow(dayAgenda.events[idx])
                                    },
                                    overflow: { count in
                                        WidgetOverflowLink(count: count, day: dayAgenda.day)
                                    }
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            } else {
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(colPadding)
                        .frame(width: colW, height: geo.size.height, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isToday ? accent.color.opacity(0.12) : .clear)
                        )
                        .opacity(isPast ? 0.5 : 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func columnEventRow(_ event: WidgetCalendarData.DayAgenda.Event) -> some View {
        let done = event.task.isCompleted
        let barColor = done ? WidgetPalette.doneText : WidgetPalette.listColor(event.projectColorHex)
        return Link(destination: WidgetDeepLink.task(event.task.id).url) {
            HStack(alignment: .top, spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(barColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    if let time = event.timeText {
                        Text(time)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.textSecondary)
                            .lineLimit(1)
                    }
                    Text(event.task.title)
                        .font(.system(size: 11))
                        .foregroundStyle(done ? WidgetPalette.doneText : WidgetPalette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - P2 (systemExtraLargePortrait)

    private func portraitXL(_ data: WidgetCalendarData) -> some View {
        let isBold = legibilityWeight == .bold
        return VStack(alignment: .leading, spacing: 0) {
            weekHeader(data)
                .padding(.bottom, 6)

            GeometryReader { geo in
                let allocation = Self.allocateWeekPortraitLimits(
                    days: data.weekDays,
                    today: data.today,
                    availableHeight: geo.size.height,
                    isBold: isBold
                )
                let extraPadding = max(0, min(5, (geo.size.height - allocation.usedHeight) / CGFloat(max(1, data.weekDays.count * 2))))

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.weekDays.enumerated()), id: \.element.id) { idx, dayAgenda in
                        let isToday = dayAgenda.day == data.today
                        let isPast = dayAgenda.day < data.today
                        let limit = idx < allocation.counts.count ? allocation.counts[idx] : 0
                        let visible = Array(dayAgenda.events.prefix(limit))
                        let overflow = max(0, dayAgenda.events.count - visible.count)

                        HStack(alignment: .top, spacing: 8) {
                            Link(destination: WidgetDeepLink.calendar(dayAgenda.day).url) {
                                VStack(spacing: 1) {
                                    Text(LocalDay.weekdaySymbols[dayAgenda.day.weekday])
                                        .font(.system(size: 10))
                                        .foregroundStyle(WidgetPalette.textSecondary)
                                    Text("\(dayAgenda.day.day)")
                                        .font(.system(size: 14, weight: isToday ? .bold : .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(isToday ? accent.onAccent : WidgetPalette.textDay)
                                        .padding(.horizontal, isToday ? 5 : 0)
                                        .frame(minWidth: 22, minHeight: 18)
                                        .background(
                                            Capsule()
                                                .fill(isToday ? accent.color : .clear)
                                        )
                                }
                                .frame(width: 30)
                            }

                            if dayAgenda.events.isEmpty {
                                Link(destination: WidgetDeepLink.calendar(dayAgenda.day).url) {
                                    Text("—")
                                        .font(.system(size: 11))
                                        .foregroundStyle(WidgetPalette.textMuted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(visible) { event in
                                        WidgetAgendaEventRow(event: event, titleSize: 12, timeSize: 11.5)
                                    }
                                    if overflow > 0 {
                                        WidgetOverflowLink(count: overflow, day: dayAgenda.day)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        .padding(.top, 4 + extraPadding)
                        .padding(.bottom, 4 + extraPadding)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(WidgetPalette.divider)
                                .frame(height: 1)
                        }
                        .opacity(isPast ? 0.5 : 1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private func weekHeader(_ data: WidgetCalendarData) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("本週")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent.text)
            Spacer(minLength: 4)
            Text(data.weekRangeText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.textSecondary)
        }
    }

    private struct PortraitAllocation {
        var counts: [Int]
        var usedHeight: CGFloat
    }

    /// Allocates visible event counts across the 7 week rows by content height so
    /// quiet days stay compact and busy days use the remaining vertical space.
    private static func allocateWeekPortraitLimits(
        days: [WidgetCalendarData.DayAgenda],
        today: LocalDay,
        availableHeight: CGFloat,
        isBold: Bool
    ) -> PortraitAllocation {
        guard !days.isEmpty else { return PortraitAllocation(counts: [], usedHeight: 0) }
        let dayBadgeH: CGFloat = isBold ? 34 : 32
        let rowChromeH: CGFloat = 9 // 1pt divider + 4pt top + 4pt bottom
        let lineH: CGFloat = isBold ? 16.5 : 15.5
        let spacing: CGFloat = 2
        let moreH: CGFloat = isBold ? 15 : 14

        func rowHeight(total: Int, shown: Int) -> CGFloat {
            if total == 0 {
                return max(dayBadgeH, lineH) + rowChromeH
            }
            let hasOverflow = shown < total
            let contentH: CGFloat
            if shown == 0 {
                contentH = moreH
            } else {
                let itemsH = CGFloat(shown) * lineH + CGFloat(shown - 1) * spacing
                contentH = hasOverflow ? (itemsH + spacing + moreH) : itemsH
            }
            return max(dayBadgeH, contentH) + rowChromeH
        }

        func totalHeight(for counts: [Int]) -> CGFloat {
            counts.enumerated().reduce(0) { acc, pair in
                acc + rowHeight(total: days[pair.offset].events.count, shown: pair.element)
            }
        }

        let full = days.map(\.events.count)
        let fullHeight = totalHeight(for: full)
        if fullHeight <= availableHeight {
            return PortraitAllocation(counts: full, usedHeight: fullHeight)
        }

        // Prioritize today, then remaining days this week, then past days.
        let todayIdx = days.firstIndex(where: { $0.day == today }) ?? 0
        let priorityOrder = Array(todayIdx..<days.count) + Array(0..<todayIdx)

        var counts = days.map { $0.events.isEmpty ? 0 : 1 }
        while totalHeight(for: counts) > availableHeight {
            guard let idx = priorityOrder.reversed().first(where: { counts[$0] > 0 }) else { break }
            counts[idx] -= 1
        }

        var grew = true
        while grew {
            grew = false
            for idx in priorityOrder where counts[idx] < days[idx].events.count {
                var candidate = counts
                candidate[idx] += 1
                if totalHeight(for: candidate) <= availableHeight {
                    counts = candidate
                    grew = true
                }
            }
        }
        return PortraitAllocation(counts: counts, usedHeight: totalHeight(for: counts))
    }
}

/// Picks the longest prefix of items (plus optional overflow footer) whose actual
/// SwiftUI layout height fits in the proposed vertical space.
private struct FittingColumnList<ItemView: View, OverflowView: View>: View {
    var totalCount: Int
    var maxShown: Int
    var gap: CGFloat
    @ViewBuilder var item: (Int) -> ItemView
    @ViewBuilder var overflow: (Int) -> OverflowView

    var body: some View {
        buildBody(shown: maxShown)
    }

    private func buildBody(shown: Int) -> AnyView {
        if shown <= 0 {
            if totalCount > 0 {
                return AnyView(overflow(totalCount))
            }
            return AnyView(EmptyView())
        }
        return AnyView(
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<shown, id: \.self) { idx in
                        item(idx)
                    }
                    if totalCount > shown {
                        overflow(totalCount - shown)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                buildBody(shown: shown - 1)
            }
        )
    }
}

struct WidgetOverflowLink: View {
    var count: Int
    var day: LocalDay

    var body: some View {
        Link(destination: WidgetDeepLink.calendar(day).url) {
            Text("+\(count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.textMuted)
                .lineLimit(1)
                .fixedSize()
        }
        .layoutPriority(1)
    }
}

struct WidgetAgendaEventRow: View {
    var event: WidgetCalendarData.DayAgenda.Event
    var titleSize: CGFloat = 12
    var timeSize: CGFloat = 11.5

    var body: some View {
        let done = event.task.isCompleted
        let dotColor = done ? WidgetPalette.doneText : WidgetPalette.listColor(event.projectColorHex)
        let titleColor = done ? WidgetPalette.doneText : WidgetPalette.text

        Link(destination: WidgetDeepLink.task(event.task.id).url) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(dotColor)
                    .frame(width: 4, height: titleSize)
                if let time = event.timeText {
                    Text(time)
                        .font(.system(size: timeSize))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
                Text(event.task.title)
                    .font(.system(size: titleSize))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }
}
