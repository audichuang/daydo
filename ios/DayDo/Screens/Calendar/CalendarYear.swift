import Observation
import SwiftUI
import DayDoCore

/// 年: twelve mini months; tapping month title opens it in 清單, tapping a day opens 日 view.
struct YearGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var year: Int
    var today: LocalDay
    var busy: Set<LocalDay>
    var isRegular: Bool = false
    var openMonth: (LocalDay) -> Void
    var openDay: (LocalDay) -> Void

    var body: some View {
        let cols = isRegular ? 4 : 3
        let masks: [UInt32] = {
            var out = [UInt32](repeating: 0, count: 12)
            for d in busy where d.year == year && (1...12).contains(d.month) && (1...31).contains(d.day) {
                out[d.month - 1] |= 1 << UInt32(d.day)
            }
            return out
        }()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isRegular ? 20 : 14, alignment: Platform.isMac ? .top : .center), count: cols), spacing: isRegular ? 22 : 18) {
            ForEach(1...12, id: \.self) { m in
                YearMonthCell(
                    year: year,
                    month: m,
                    today: today,
                    busyMask: masks[m - 1],
                    isRegular: isRegular,
                    reduceMotion: reduceMotion,
                    openMonth: openMonth,
                    openDay: openDay
                )
                .equatable()
            }
        }
        .padding(.top, 8)
    }
}

struct YearMonthCell: View, Equatable {
    @Environment(\.accent) private var accent
    var year: Int
    var month: Int
    var today: LocalDay
    var busyMask: UInt32
    var isRegular: Bool
    var reduceMotion: Bool
    var openMonth: (LocalDay) -> Void
    var openDay: (LocalDay) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.year == rhs.year
            && lhs.month == rhs.month
            && lhs.today == rhs.today
            && lhs.busyMask == rhs.busyMask
            && lhs.isRegular == rhs.isRegular
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        let first = LocalDay(year: year, month: month, day: 1)
        let days = MonthLayout.gridDays(for: first)
        let weekCount = days.count / 7
        let dayFontSize: CGFloat = isRegular ? 11 : 8.5
        let circleSize: CGFloat = isRegular ? 18 : 13
        let rowHeight: CGFloat = isRegular ? 20 : 14

        VStack(alignment: .leading, spacing: 4) {
            Button { openMonth(first) } label: {
                Text("\(month)月").txt(isRegular ? 16 : 15, .bold).foregroundStyle(month == today.month && year == today.year ? accent.text : Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.press)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text(verbatim: "\(year) 年 \(month) 月"))

            VStack(spacing: 2) {
                if Platform.isMac {
                    HStack(spacing: 0) {
                        ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { w in
                            Text(w).font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: 16)
                        }
                    }
                    .accessibilityHidden(true)
                }
                ForEach(0..<weekCount, id: \.self) { w in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { c in
                            let d = days[w * 7 + c]
                            if d.month == month {
                                let isToday = d == today
                                let isBusy = (busyMask & (1 << UInt32(d.day))) != 0
                                Button { openDay(d) } label: {
                                    Text("\(d.day)")
                                        .font(.system(size: dayFontSize, weight: isToday ? .bold : .regular))
                                        .foregroundStyle(isToday ? accent.onAccent : (isBusy ? accent.text : Palette.textSecondary))
                                        .frame(width: circleSize, height: circleSize)
                                        .background(Circle().fill(isToday ? accent.color : .clear))
                                        .frame(height: rowHeight).frame(maxWidth: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.press(scale: 0.9, opacity: 0.85))
                                .hoverEffect(.highlight)
                                .accessibilityIdentifier("yearDay.\(d)")
                                .accessibilityLabel(DateText.full(d))
                            } else {
                                Color.clear.frame(height: rowHeight).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }
}
