import SwiftUI
import WidgetKit
import DayDoCore

struct WeekWidgetView: View {
    var data: WidgetCalendarData?
    var family: WidgetFamily
    var accent: WidgetAccent

    var body: some View {
        Group {
            if let data {
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
