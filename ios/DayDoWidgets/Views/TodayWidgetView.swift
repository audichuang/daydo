import SwiftUI
import WidgetKit
import DayDoCore

struct TodayWidgetView: View {
    var data: WidgetTodayData?
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
                    title: "今天",
                    message: "開啟 DayDo 以顯示任務",
                    accent: accent
                )
            }
        }
        .widgetPadding(for: family)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.today.url)
    }

    private func small(_ data: WidgetTodayData) -> some View {
        let items = Array(data.allItems.prefix(3))
        let extra = max(0, data.totalCount - items.count)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("今天")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent.text)
                Spacer(minLength: 4)
                Text("\(data.totalCount)")
                    .font(.system(size: 24, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.text)
            }

            if items.isEmpty {
                Spacer(minLength: 0)
                Text("今天沒有待辦")
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetPalette.textTertiary)
                Spacer(minLength: 0)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        WidgetPriorityBox(priority: item.task.priority, size: 12, cornerRadius: 4, lineWidth: 1.6)
                        Text(item.task.title)
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetPalette.text)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if extra > 0 {
                    Text("另有 \(extra) 項")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.textTertiary)
                }
            }
        }
    }

    private func medium(_ data: WidgetTodayData) -> some View {
        let items = Array(data.allItems.prefix(4))
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text("週\(LocalDay.weekdaySymbols[data.today.weekday])")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent.text)
                Text("\(data.today.day)")
                    .font(.system(size: 36, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.text)
                    .lineSpacing(0)
                Spacer(minLength: 0)
                Text("剩 \(data.totalCount) 項")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.textTertiary)
            }
            .frame(width: 84, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Spacer(minLength: 0)
                    Text("今天沒有待辦")
                        .font(.system(size: 13))
                        .foregroundStyle(WidgetPalette.textTertiary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        Link(destination: WidgetDeepLink.task(item.task.id).url) {
                            HStack(spacing: 8) {
                                WidgetPriorityBox(priority: item.task.priority, size: 15, cornerRadius: 5, lineWidth: 1.8)
                                Text(item.task.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(WidgetPalette.text)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if !item.timeLabel.isEmpty {
                                    Text(item.timeLabel)
                                        .font(.system(size: 11, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(item.isOverdue ? WidgetPalette.overdue : accent.text)
                                }
                            }
                            .frame(height: 30)
                        }
                        if idx < items.count - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                    if items.count < 4 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func large(_ data: WidgetTodayData) -> some View {
        let maxVisible = 7
        let visibleOverdue = Array(data.overdueItems.prefix(maxVisible))
        let remainingBudget = max(0, maxVisible - visibleOverdue.count)
        let visibleToday = Array(data.todayItems.prefix(remainingBudget))
        let shownCount = visibleOverdue.count + visibleToday.count
        let extra = max(0, data.totalCount - shownCount)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("今天")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent.text)
                Text("\(data.today.month) 月 \(data.today.day) 日 週\(LocalDay.weekdaySymbols[data.today.weekday])・\(data.totalCount) 項")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.textTertiary)
            }

            if data.totalCount == 0 {
                Spacer(minLength: 0)
                Text("今天沒有待辦")
                    .font(.system(size: 13))
                    .foregroundStyle(WidgetPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                if !visibleOverdue.isEmpty {
                    largeGroup(title: "已逾期", titleColor: WidgetPalette.overdue, items: visibleOverdue)
                }
                if !visibleToday.isEmpty {
                    largeGroup(title: "今天", titleColor: WidgetPalette.textSection, items: visibleToday)
                }
                Spacer(minLength: 0)
                if extra > 0 {
                    Text("另有 \(extra) 項")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.textTertiary)
                }
            }
        }
    }

    private func largeGroup(title: String, titleColor: Color, items: [WidgetTodayData.Item]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(titleColor)
                .padding(.top, 4)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Link(destination: WidgetDeepLink.task(item.task.id).url) {
                    HStack(spacing: 8) {
                        WidgetPriorityBox(priority: item.task.priority, size: 15, cornerRadius: 5, lineWidth: 1.8)
                        Text(item.task.title)
                            .font(.system(size: 13))
                            .foregroundStyle(WidgetPalette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if !item.timeLabel.isEmpty {
                            Text(item.timeLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(item.isOverdue ? WidgetPalette.overdue : accent.text)
                        }
                    }
                    .frame(minHeight: 34)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle()
                                .fill(WidgetPalette.divider)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
    }
}
