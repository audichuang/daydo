import SwiftUI
import UIKit
import WidgetKit
import DayDoCore

struct WeekWidgetView: View {
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
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(todayEvents) { event in
                        WidgetAgendaEventRow(event: event, titleSize: 12, timeSize: 11.5)
                    }
                }
            }

            Spacer(minLength: 0)
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
                                Text("+\(extra)")
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(WidgetPalette.textMuted)
                                    .fixedSize()
                                    .layoutPriority(1)
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
                let availH = max(0, geo.size.height - colPadding * 2 - headerH - itemGap)
                let textW = max(12, colW - colPadding * 2 - 3 - 4)

                HStack(alignment: .top, spacing: colSpacing) {
                    ForEach(data.weekDays) { dayAgenda in
                        let isToday = dayAgenda.day == data.today
                        let isPast = dayAgenda.day < data.today
                        let (visible, overflow) = Self.fitColumnEvents(
                            dayAgenda.events,
                            availableHeight: availH,
                            textWidth: textW,
                            gap: itemGap
                        )

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

                            ForEach(visible) { event in
                                let done = event.task.isCompleted
                                let barColor = done ? WidgetPalette.doneText : WidgetPalette.listColor(event.projectColorHex)
                                Link(destination: WidgetDeepLink.task(event.task.id).url) {
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

                            if overflow > 0 {
                                Text("+\(overflow)")
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(WidgetPalette.textMuted)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
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

    // MARK: - P2 (systemExtraLargePortrait)

    private func portraitXL(_ data: WidgetCalendarData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            weekHeader(data)
                .padding(.bottom, 6)

            GeometryReader { geo in
                let rowH = geo.size.height / 7
                let usableH = max(0, rowH - 6)

                VStack(spacing: 0) {
                    ForEach(data.weekDays) { dayAgenda in
                        let isToday = dayAgenda.day == data.today
                        let isPast = dayAgenda.day < data.today
                        let (visible, overflow) = Self.fitSingleLineEvents(
                            dayAgenda.events,
                            availableHeight: usableH,
                            rowHeight: 14,
                            spacing: 1.5,
                            moreHeight: 13
                        )

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
                                VStack(alignment: .leading, spacing: 1.5) {
                                    ForEach(visible) { event in
                                        WidgetAgendaEventRow(event: event, titleSize: 11.5, timeSize: 11)
                                    }
                                    if overflow > 0 {
                                        Text("+\(overflow)")
                                            .font(.system(size: 11, weight: .medium))
                                            .monospacedDigit()
                                            .foregroundStyle(WidgetPalette.textMuted)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        .padding(.top, 3)
                        .padding(.bottom, 2)
                        .frame(height: rowH, alignment: .topLeading)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(WidgetPalette.divider)
                                .frame(height: 1)
                        }
                        .opacity(isPast ? 0.5 : 1)
                    }
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

    private static func estimatedColumnEventHeight(
        _ event: WidgetCalendarData.DayAgenda.Event,
        textWidth: CGFloat
    ) -> CGFloat {
        let titleFont = UIFont.systemFont(ofSize: 11)
        let rect = (event.task.title as NSString).boundingRect(
            with: CGSize(width: max(1, textWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont],
            context: nil
        )
        let lines = max(1, min(2, Int(ceil(rect.height / titleFont.lineHeight))))
        let titleH = CGFloat(lines) * ceil(titleFont.lineHeight)
        let timeH: CGFloat = event.timeText == nil ? 0 : 13
        return titleH + timeH + 1
    }

    private static func fitColumnEvents(
        _ events: [WidgetCalendarData.DayAgenda.Event],
        availableHeight: CGFloat,
        textWidth: CGFloat,
        gap: CGFloat
    ) -> ([WidgetCalendarData.DayAgenda.Event], Int) {
        guard !events.isEmpty else { return ([], 0) }
        let heights = events.map { estimatedColumnEventHeight($0, textWidth: textWidth) }
        let totalHeight = heights.reduce(0, +) + gap * CGFloat(max(0, events.count - 1))
        if totalHeight <= availableHeight {
            return (events, 0)
        }
        let moreH: CGFloat = 14
        let budget = availableHeight - moreH
        var used: CGFloat = 0
        var count = 0
        for h in heights {
            let needed = (count > 0 ? gap : 0) + h + gap
            if used + needed <= budget {
                used += (count > 0 ? gap : 0) + h
                count += 1
            } else {
                break
            }
        }
        return (Array(events.prefix(count)), events.count - count)
    }

    private static func fitSingleLineEvents(
        _ events: [WidgetCalendarData.DayAgenda.Event],
        availableHeight: CGFloat,
        rowHeight: CGFloat,
        spacing: CGFloat,
        moreHeight: CGFloat
    ) -> ([WidgetCalendarData.DayAgenda.Event], Int) {
        guard !events.isEmpty else { return ([], 0) }
        let step = rowHeight + spacing
        let maxAll = max(0, Int(floor((availableHeight + spacing) / step)))
        if events.count <= maxAll {
            return (events, 0)
        }
        let maxWithMore = max(0, Int(floor((availableHeight - moreHeight) / step)))
        let shown = min(events.count, maxWithMore)
        return (Array(events.prefix(shown)), events.count - shown)
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
