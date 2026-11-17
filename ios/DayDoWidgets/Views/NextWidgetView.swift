import SwiftUI
import WidgetKit
import DayDoCore

struct NextWidgetView: View {
    var data: WidgetNextData?
    var family: WidgetFamily
    var accent: WidgetAccent

    var body: some View {
        Group {
            if let data {
                switch family {
                case .systemSmall:
                    small(data)
                case .systemMedium:
                    medium(data)
                case .systemLarge:
                    large(data)
                default:
                    small(data)
                }
            } else {
                WidgetUnavailableView(
                    title: "接下來",
                    message: "開啟 DayDo 以顯示行程",
                    accent: accent
                )
            }
        }
        .widgetPadding(for: family)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(primaryURL)
    }

    private var primaryURL: URL {
        if let id = data?.currentOrNext?.task.id {
            return WidgetDeepLink.task(id).url
        }
        if family == .systemLarge, let today = data?.today {
            return WidgetDeepLink.calendar(today).url
        }
        return WidgetDeepLink.today.url
    }

    private func small(_ data: WidgetNextData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let next = data.currentOrNext {
                Text(headerText(for: next, today: data.today))
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent.text)

                HStack(alignment: .top, spacing: 7) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(WidgetPalette.listColor(next.projectColorHex))
                        .frame(width: 3)
                    Text(next.task.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(WidgetPalette.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

                Text(metaLine(for: next))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 10)

                Spacer(minLength: 0)

                if let second = data.after.first {
                    HStack(spacing: 0) {
                        Text("之後：")
                            .layoutPriority(1)
                        Text(second.task.title)
                            .lineLimit(1)
                        Text(" \(dayPrefix(for: second, today: data.today))\(second.startTimeText)")
                            .monospacedDigit()
                            .layoutPriority(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetPalette.textTertiary)
                }
            } else {
                Text("接下來")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent.text)
                Spacer(minLength: 0)
                Text("沒有即將開始的行程")
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetPalette.textTertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private func medium(_ data: WidgetNextData) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let next = data.currentOrNext {
                    Text(headerText(for: next, today: data.today))
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(accent.text)

                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(WidgetPalette.listColor(next.projectColorHex))
                            .frame(width: 3)
                        Text(next.task.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(WidgetPalette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                    Text(metaLine(for: next))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.textSecondary)
                        .lineLimit(1)
                        .padding(.leading, 10)

                    Spacer(minLength: 0)

                    let details = detailLine(for: next.task)
                    if !details.isEmpty {
                        Text(details)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.textTertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text("接下來")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent.text)
                    Spacer(minLength: 0)
                    Text("沒有即將開始的行程")
                        .font(.system(size: 13))
                        .foregroundStyle(WidgetPalette.textTertiary)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 6) {
                Text("之後")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WidgetPalette.textTertiary)

                let upcoming = Array(data.after.prefix(2))
                if upcoming.isEmpty {
                    Text("沒有更多行程")
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetPalette.textMuted)
                } else {
                    ForEach(upcoming) { item in
                        Link(destination: WidgetDeepLink.task(item.task.id).url) {
                            HStack(alignment: .top, spacing: 6) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(WidgetPalette.listColor(item.projectColorHex))
                                    .frame(width: 3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.task.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(WidgetPalette.text)
                                        .lineLimit(1)
                                    Text("\(dayPrefix(for: item, today: data.today))\(item.timeRangeText)")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(WidgetPalette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 146, alignment: .topLeading)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(WidgetPalette.dividerSoft)
                    .frame(width: 1)
            }
        }
    }

    private func large(_ data: WidgetNextData) -> some View {
        let winStartMin = data.windowStartHour * 60
        let totalMinutes = CGFloat((data.windowEndHour - data.windowStartHour) * 60)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("接下來")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent.text)
                Text(String(format: "今天 %02d:00 – %02d:00", data.windowStartHour, data.windowEndHour))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.textTertiary)
            }

            if !data.allDayToday.isEmpty {
                let shownChips = Array(data.allDayToday.prefix(3))
                let extraAllDay = max(0, data.allDayToday.count - shownChips.count)
                HStack(spacing: 6) {
                    ForEach(shownChips) { chip in
                        Link(destination: WidgetDeepLink.task(chip.task.id).url) {
                            Text(chip.displayTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(WidgetPalette.tintedListText(chip.projectColorHex))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(WidgetPalette.listColor(chip.projectColorHex).opacity(0.20))
                                )
                        }
                    }
                    if extraAllDay > 0 {
                        Text("+\(extraAllDay)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(WidgetPalette.divider)
                            )
                    }
                }
            }

            GeometryReader { geo in
                let topPad: CGFloat = 7
                let bottomPad: CGFloat = 10
                let usableH = max(40, geo.size.height - topPad - bottomPad)
                let gutter: CGFloat = 40
                let trackW = max(40, geo.size.width - gutter)

                ZStack(alignment: .topLeading) {
                    ForEach(data.windowStartHour...data.windowEndHour, id: \.self) { hour in
                        let y = topPad + CGFloat((hour - data.windowStartHour) * 60) / totalMinutes * usableH
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(WidgetPalette.divider)
                                .frame(width: geo.size.width, height: 1)
                            Text(String(format: "%02d:00", hour))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(WidgetPalette.textMuted)
                                .padding(.trailing, 4)
                                .background(WidgetPalette.background)
                        }
                        .frame(height: 12, alignment: .leading)
                        .offset(y: y - 6)
                    }

                    ForEach(data.timelineBlocks) { block in
                        let colW = trackW / CGFloat(max(1, block.lanes))
                        let laneGap: CGFloat = block.lanes > 1 ? 4 : 0
                        let x = gutter + colW * CGFloat(block.lane) + (block.lane > 0 ? laneGap / 2 : 0)
                        let w = max(20, colW - (block.lanes > 1 ? laneGap / 2 : 0))
                        let y = topPad + CGFloat(block.startMinute - winStartMin) / totalMinutes * usableH
                        let h = max(18, CGFloat(block.endMinute - block.startMinute) / totalMinutes * usableH)

                        let bg = block.isPrimary
                            ? accent.color
                            : WidgetPalette.listColor(block.projectColorHex).opacity(0.22)
                        let fg = block.isPrimary
                            ? accent.onAccent
                            : WidgetPalette.tintedListText(block.projectColorHex)

                        Link(destination: WidgetDeepLink.task(block.task.id).url) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(block.task.title)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(fg)
                                    .lineLimit(1)
                                if h >= 32 {
                                    Text(block.timeText)
                                        .font(.system(size: 10))
                                        .monospacedDigit()
                                        .foregroundStyle(fg.opacity(0.85))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(width: w, height: h, alignment: .topLeading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(bg)
                            )
                            .clipped()
                        }
                        .offset(x: x, y: y)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headerText(for item: WidgetNextData.TimedItem, today: LocalDay) -> String {
        let status = item.isOngoing ? "進行中" : "接下來"
        return "\(status)・\(dayPrefix(for: item, today: today))\(item.startTimeText)"
    }

    private func dayPrefix(for item: WidgetNextData.TimedItem, today: LocalDay) -> String {
        guard let day = item.task.schedule?.startDay, day != today else { return "" }
        return DateText.relative(day, today: today) + " "
    }

    private func metaLine(for item: WidgetNextData.TimedItem) -> String {
        if let projectName = item.projectName, !projectName.isEmpty {
            return "\(item.timeRangeText)・\(projectName)"
        }
        return item.timeRangeText
    }

    private func detailLine(for task: TodoTask) -> String {
        var parts: [String] = []
        if !task.items.isEmpty {
            parts.append("子任務 \(task.completedItemCount)/\(task.items.count)")
        }
        if !task.attachments.isEmpty {
            parts.append("附件 \(task.attachments.count)")
        }
        if task.commentCount > 0 {
            parts.append("留言 \(task.commentCount)")
        }
        return parts.joined(separator: "・")
    }
}
