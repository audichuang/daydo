import SwiftUI
import DayDoCore

/// 4a / 4b · Date panel: summary cards first, calendar and option rows
/// expand on demand. 確定 commits; 取消 returns to the detail.
struct DatePanel: View {
    @Environment(\.accent) private var accent
    @Binding var draft: DateDraft
    var today: LocalDay
    var cancel: () -> Void
    var confirm: () -> Void
    var openTime: () -> Void

    @State private var tab = 0
    @State private var calOpen = false
    @State private var endCalOpen = false
    @State private var open: Set<String> = []
    @State private var month = LocalDay(year: 2000, month: 1, day: 1)
    @State private var endMonth = LocalDay(year: 2000, month: 1, day: 1)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PillButton(title: "取消", action: cancel)
                Spacer()
                HStack(spacing: 2) {
                    tabButton("日期", 0)
                    tabButton("持續時間", 1)
                }
                .padding(3)
                .background(Capsule().fill(Palette.control))
                Spacer()
                PillButton(title: "確定", kind: .primary, action: confirm)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .frame(height: 68)

            ScrollView {
                VStack(spacing: 12) {
                    if tab == 0 { summaryCards } else { durationCard }
                    if calOpen { calendar }
                    optionsCard
                    Button("清除日期") {
                        draft.day = nil
                        draft.endDay = nil
                        draft.reminders = []
                        draft.repeatRule = nil
                    }
                    .txt(15)
                    .foregroundStyle(Palette.danger)
                    .frame(height: 44)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            month = (draft.day ?? today).firstOfMonth
            endMonth = (draft.endDay ?? draft.day ?? today).firstOfMonth
            if draft.day == nil { calOpen = true }
        }
    }

    func tabButton(_ title: String, _ i: Int) -> some View {
        Button { withAnimation(.snappy) { tab = i } } label: {
            Text(title).txt(14, .semibold)
                .foregroundStyle(tab == i ? .white : Palette.textSecondary)
                .padding(.horizontal, 16).frame(height: 32)
                .background(Capsule().fill(tab == i ? Palette.handle : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == i ? .isSelected : [])
    }

    var dateText: String { draft.day.map(DateText.full) ?? "未設定日期" }

    var relText: String {
        guard let d = draft.day else { return "" }
        let n = today.days(until: d)
        if n == 0 { return "今天" }
        return n > 0 ? "\(n) 天後" : "\(-n) 天前"
    }

    var timeText: String {
        if draft.allDay {
            if let e = draft.endDay, let d = draft.day, e > d { return "全天・\(d.days(until: e) + 1) 天" }
            return "全天"
        }
        if draft.end <= draft.start { return DateText.hm(draft.start) }
        return DateText.hm(draft.start) + " – " + (draft.end >= 1440 ? "隔日 " : "") + DateText.hm(draft.end)
    }

    var durText: String {
        if draft.allDay { return "整天" }
        if draft.end <= draft.start { return "時間點" }
        return "持續 " + DateText.duration(draft.duration)
    }

    var summaryCards: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.snappy) { calOpen.toggle() } } label: {
                card("日期", dateText, relText, highlighted: calOpen)
            }
            .buttonStyle(.plain)
            .accessibilityValue(calOpen ? "日曆已展開" : "")
            Button {
                if draft.day == nil { draft.day = today }
                if draft.allDay { setTimed() }
                openTime()
            } label: {
                card("時間", timeText, durText, highlighted: false)
            }
            .buttonStyle(.plain)
        }
    }

    func card(_ label: String, _ value: String, _ sub: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).txt(12).foregroundStyle(Palette.textSecondary)
            Text(value).txt(17, .bold).foregroundStyle(accent.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).txt(12).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(highlighted ? accent.color : Palette.separator, lineWidth: 1))
    }

    var durationCard: some View {
        VStack(spacing: 0) {
            if draft.allDay {
                durRow("開始", draft.day.map(DateText.full) ?? "未設定", "") { withAnimation(.snappy) { calOpen.toggle() } }
                durRow("結束", (draft.endDay ?? draft.day).map(DateText.full) ?? "未設定", "") { withAnimation(.snappy) { endCalOpen.toggle() } }
                if endCalOpen {
                    MonthPicker(month: $endMonth, selected: draft.endDay ?? draft.day, today: today) { d in
                        if let s = draft.day, d >= s { draft.endDay = d > s ? d : nil }
                        withAnimation(.snappy) { endCalOpen = false }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                durRow("開始", dateText, DateText.hm(draft.start), action: openTime)
                durRow("結束", draft.day.map { DateText.full($0.adding(days: draft.end / 1440)) } ?? "", DateText.hm(draft.end), action: openTime)
            }
            HStack {
                Text("總時長").txt(14).foregroundStyle(Palette.textMuted)
                Spacer()
                Text(totalText).txt(14, .semibold).foregroundStyle(Palette.text)
            }
            .frame(minHeight: 48)
        }
        .padding(.horizontal, 14)
        .card(16, color: Palette.raised)
    }

    var totalText: String {
        if draft.allDay {
            guard let d = draft.day else { return "—" }
            return "\((draft.endDay.map { d.days(until: $0) } ?? 0) + 1) 天"
        }
        return draft.end > draft.start ? DateText.duration(draft.duration) : "時間點"
    }

    func durRow(_ label: String, _ date: String, _ time: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(label).txt(13).foregroundStyle(Palette.textSecondary).frame(width: 40, alignment: .leading)
                Text(date).txt(15).foregroundStyle(Palette.text)
                Spacer()
                Text(time).txt(17, .bold).foregroundStyle(accent.text)
            }
            .frame(minHeight: 56)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorSoft).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var nextMonday: LocalDay {
        let n = (8 - today.weekday) % 7
        return today.adding(days: n == 0 ? 7 : n)
    }

    var calendar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                quick("今天", today)
                quick("明天", today.adding(days: 1))
                quick("下週一", nextMonday)
                quick("無日期", nil)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            MonthPicker(month: $month, selected: draft.day, today: today) { d in pickDay(d) }
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .card(16, color: Palette.raised)
    }

    func quick(_ label: String, _ d: LocalDay?) -> some View {
        let on = draft.day == d
        return Button {
            if let d { pickDay(d); month = d.firstOfMonth } else { draft.day = nil; draft.endDay = nil }
        } label: {
            Text(label).txt(13, .semibold)
                .foregroundStyle(on ? accent.onAccent : Palette.textBody)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? accent.color : Palette.chip))
        }
        .buttonStyle(.plain)
    }

    func pickDay(_ d: LocalDay) {
        // Keep multi-day length when moving the start.
        if let s = draft.day, let e = draft.endDay { draft.endDay = d.adding(days: s.days(until: e)) }
        draft.day = d
    }

    func setTimed() {
        draft.allDay = false
        draft.endDay = nil
        if draft.timeZone == nil { draft.timeZone = TimeZone.current.identifier }
        // Convert all-day reminders into the timed preset.
        draft.reminders = draft.reminders.isEmpty ? [] : [Reminder(offsetSeconds: -900).trigger]
    }

    // MARK: Options

    var optionsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("全天").txt(15).foregroundStyle(Palette.text)
                Spacer()
                Toggle("全天", isOn: Binding(get: { draft.allDay }, set: { on in
                    if on {
                        draft.allDay = true
                        draft.reminders = draft.reminders.isEmpty ? [] : [Reminder(offsetSeconds: 9 * 3600).trigger]
                    } else {
                        setTimed()
                    }
                }))
                .labelsHidden()
                .tint(accent.color)
            }
            .frame(minHeight: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorSoft).frame(height: 1) }

            if !draft.allDay {
                optionRow("tz", "時區", TimeZoneOption.label(draft.timeZone), highlight: false) {
                    ForEach(TimeZoneOption.options, id: \.self) { id in
                        OptionChip(label: TimeZoneOption.label(id), on: draft.timeZone == id) { draft.timeZone = id }
                    }
                }
            }
            optionRow("rem", "提醒", reminderSummary, highlight: !draft.reminders.isEmpty) {
                ForEach(draft.allDay ? Reminder.allDayPresets : Reminder.timedPresets, id: \.self) { r in
                    let on = draft.reminders.contains(r.trigger)
                    OptionChip(label: r.label(allDay: draft.allDay), on: on) {
                        if on { draft.reminders.removeAll { $0 == r.trigger } } else { draft.reminders.append(r.trigger) }
                    }
                }
            }
            .disabled(draft.day == nil)
            optionRow("rep", "重複", repeatSummary, highlight: false, last: true) {
                OptionChip(label: "不重複", on: draft.repeatRule == nil) { draft.repeatRule = nil }
                ForEach(Recurrence.presets(anchor: draft.day ?? today), id: \.self) { r in
                    OptionChip(label: r.label(anchor: draft.day ?? today), on: draft.repeatRule.flatMap(Recurrence.init(rrule:)) == r) { draft.repeatRule = r.rrule }
                }
            }
            .disabled(draft.day == nil)
        }
        .padding(.horizontal, 14)
        .card(16, color: Palette.raised)
    }

    var reminderSummary: String {
        if draft.reminders.isEmpty { return "無" }
        return draft.reminders.compactMap(Reminder.init(trigger:)).map { $0.label(allDay: draft.allDay) }.joined(separator: "、")
    }

    var repeatSummary: String {
        guard let r = draft.repeatRule else { return "不重複" }
        return Recurrence(rrule: r)?.label(anchor: draft.day ?? today) ?? r
    }

    func optionRow<Opts: View>(_ key: String, _ label: String, _ value: String, highlight: Bool, last: Bool = false, @ViewBuilder options: () -> Opts) -> some View {
        let isOpen = open.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { if isOpen { open.remove(key) } else { open.insert(key) } }
            } label: {
                HStack(spacing: 8) {
                    Text(label).txt(15).foregroundStyle(Palette.text)
                    Spacer()
                    Text(value).txt(14).foregroundStyle(highlight ? accent.text : Palette.textSecondary).lineLimit(1).frame(maxWidth: 200, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "已展開" : "")
            if isOpen {
                FlowLayout(spacing: 6) { options() }.padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Palette.separatorSoft).frame(height: 1) } }
    }
}

enum TimeZoneOption {
    static var options: [String?] {
        var list: [String?] = [TimeZone.current.identifier]
        for z in ["Asia/Taipei", "Asia/Tokyo", "America/Los_Angeles", "Europe/London"] where !list.contains(z) { list.append(z) }
        list.append(nil)
        return list
    }

    static let cities = ["Asia/Taipei": "台北", "Asia/Tokyo": "東京", "Asia/Shanghai": "上海", "Asia/Hong_Kong": "香港", "Asia/Singapore": "新加坡",
                         "America/Los_Angeles": "洛杉磯", "America/New_York": "紐約", "Europe/London": "倫敦", "Europe/Paris": "巴黎", "UTC": "UTC"]

    static func label(_ id: String?) -> String {
        guard let id, let tz = TimeZone(identifier: id) else { return "浮動時間（跟著裝置）" }
        let secs = tz.secondsFromGMT()
        let h = secs / 3600, m = abs(secs % 3600) / 60
        let gmt = "GMT" + (secs >= 0 ? "+" : "-") + "\(abs(h))" + (m > 0 ? String(format: ":%02d", m) : "")
        let city = cities[id] ?? (id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id)
        return "\(city) \(gmt)"
    }
}
