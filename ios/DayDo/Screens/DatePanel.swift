import SwiftUI
import DayDoCore

/// Date editor used by both the composer and the task detail. Page 1 is the
/// date panel (calendar always open, then 時間／提醒／重複 rows); page 2 is the
/// time-block editor reached from 持續時間.
struct DateEditorFlow: View {
    @Binding var draft: DateDraft
    var today: LocalDay
    var title: String
    var excludeTaskId: String?
    var cancel: () -> Void
    var confirm: () -> Void
    @State private var timeline = false

    var body: some View {
        if timeline {
            TimeBlockEditor(draft: $draft, title: title, excludeTaskId: excludeTaskId, cancel: { timeline = false }, save: { timeline = false })
        } else {
            DatePanel(draft: $draft, today: today, cancel: cancel, confirm: confirm, openTime: { timeline = true })
        }
    }
}

struct DatePanel: View {
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var draft: DateDraft
    var today: LocalDay
    var cancel: () -> Void
    var confirm: () -> Void
    var openTime: () -> Void

    @State private var tab = 0
    @State private var expanded: String?
    @State private var month = LocalDay(year: 2000, month: 1, day: 1)
    @State private var endMonth = LocalDay(year: 2000, month: 1, day: 1)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                circleButton("xmark", fill: Palette.control, fg: Palette.text, label: "取消", action: cancel)
                Spacer()
                HStack(spacing: 2) {
                    tabButton("日期", 0)
                    tabButton("持續時間", 1)
                }
                .padding(3)
                .background(Capsule().fill(Palette.control))
                Spacer()
                circleButton("checkmark", fill: accent.color, fg: accent.onAccent, label: "確定", action: confirm)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 14) {
                    if tab == 0 { dateTab } else { durationTab }
                    Button("清除") {
                        draft.day = nil
                        draft.endDay = nil
                        draft.allDay = true
                        draft.reminders = []
                        draft.repeatRule = nil
                    }
                    .txt(16)
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .background(Palette.card)
        .onAppear {
            month = (draft.day ?? today).firstOfMonth
            endMonth = (draft.endDay ?? draft.day ?? today).firstOfMonth
        }
    }

    func circleButton(_ icon: String, fill: Color, fg: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(fg)
                .frame(width: 44, height: 44).background(Circle().fill(fill))
        }
        .buttonStyle(.press)
        .accessibilityLabel(label)
    }

    func tabButton(_ title: String, _ i: Int) -> some View {
        Button { withAnimation(Motion.toggle(reduceMotion)) { tab = i; expanded = nil } } label: {
            Text(title).txt(15, .semibold)
                .foregroundStyle(tab == i ? .white : Palette.textSecondary)
                .padding(.horizontal, 18).frame(height: 36)
                .background(Capsule().fill(tab == i ? Palette.handle : .clear))
        }
        .buttonStyle(.press)
        .accessibilityIdentifier(i == 0 ? "dateTab" : "durationTab")
        .accessibilityAddTraits(tab == i ? .isSelected : [])
    }

    // MARK: 日期

    var dateTab: some View {
        VStack(spacing: 14) {
            MonthPicker(month: $month, selected: draft.day, today: today) { d in pickDay(d) }
            VStack(spacing: 0) {
                row("clock", "時間", timeValue, key: "time", highlight: !draft.allDay)
                if expanded == "time" {
                    VStack(spacing: 6) {
                        wheel(minute: draft.start) { setStartTime($0) }
                        Button("不設時間（全天）") { withAnimation(Motion.toggle(reduceMotion)) { draft.allDay = true; expanded = nil } }
                            .txt(14, .semibold).foregroundStyle(accent.text).buttonStyle(.plain).padding(.bottom, 10)
                    }
                }
                divider
                reminderMenu
                divider
                repeatMenu
                if !draft.allDay {
                    divider
                    zoneMenu
                }
            }
            .padding(.horizontal, 16)
            .card(18, color: Palette.raised)
        }
    }

    var timeValue: String {
        if draft.allDay { return "無" }
        if draft.end > draft.start { return DateText.hm(draft.start) + " – " + (draft.end >= 1440 ? "隔日 " : "") + DateText.hm(draft.end) }
        return DateText.hm(draft.start)
    }

    func setStartTime(_ m: Int) {
        if draft.day == nil { draft.day = today }
        let len = draft.allDay ? 0 : max(0, draft.end - draft.start)
        if draft.allDay {
            draft.allDay = false
            draft.endDay = nil
            if draft.timeZone == nil { draft.timeZone = TimeZone.current.identifier }
            draft.reminders = draft.reminders.isEmpty ? [] : [Reminder(offsetSeconds: 0).trigger]
        }
        draft.start = m
        draft.end = m + len
    }

    func pickDay(_ d: LocalDay) {
        if let s = draft.day, let e = draft.endDay { draft.endDay = d.adding(days: s.days(until: e)) }
        draft.day = d
    }

    var divider: some View { Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.leading, 40) }

    func rowLabel(_ icon: String, _ label: String, _ value: String, highlight: Bool, chevron: String = "chevron.up.chevron.down") -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Palette.textBody).frame(width: 26)
            Text(label).txt(17).foregroundStyle(Palette.text)
            Spacer()
            Text(value).txt(15).foregroundStyle(highlight ? accent.text : Palette.textSecondary).lineLimit(1)
            Image(systemName: chevron).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    func row(_ icon: String, _ label: String, _ value: String, key: String, highlight: Bool) -> some View {
        Button {
            withAnimation(Motion.toggle(reduceMotion)) { expanded = expanded == key ? nil : key }
        } label: {
            rowLabel(icon, label, value, highlight: highlight)
        }
        .buttonStyle(.press(scale: 0.985, opacity: 0.92))
        .accessibilityValue(value)
    }

    var reminderMenu: some View {
        let presets = draft.allDay ? Reminder.allDayPresets : Reminder.timedPresets
        let summary = draft.reminders.isEmpty ? "無" : draft.reminders.compactMap(Reminder.init(trigger:)).map { $0.label(allDay: draft.allDay) }.joined(separator: "、")
        return Menu {
            Button("無") { draft.reminders = [] }
            ForEach(presets, id: \.self) { r in
                let on = draft.reminders.contains(r.trigger)
                Button {
                    if draft.day == nil { draft.day = today }
                    if on { draft.reminders.removeAll { $0 == r.trigger } } else { draft.reminders.append(r.trigger) }
                } label: {
                    if on { Label(r.label(allDay: draft.allDay), systemImage: "checkmark") } else { Text(r.label(allDay: draft.allDay)) }
                }
            }
        } label: {
            rowLabel("alarm", "提醒時間", summary, highlight: !draft.reminders.isEmpty)
        }
        .menuActionDismissBehavior(.disabled)
    }

    var repeatMenu: some View {
        let anchor = draft.day ?? today
        let current = draft.repeatRule.flatMap(Recurrence.init(rrule:))
        return Menu {
            Button("無") { draft.repeatRule = nil }
            ForEach(Recurrence.presets(anchor: anchor), id: \.self) { r in
                Button {
                    if draft.day == nil { draft.day = today }
                    draft.repeatRule = r.rrule
                } label: {
                    if current == r { Label(r.label(anchor: anchor), systemImage: "checkmark") } else { Text(r.label(anchor: anchor)) }
                }
            }
        } label: {
            rowLabel("repeat", "重複", current?.label(anchor: anchor) ?? (draft.repeatRule ?? "無"), highlight: draft.repeatRule != nil)
        }
    }

    var zoneMenu: some View {
        Menu {
            ForEach(TimeZoneOption.options, id: \.self) { id in
                Button {
                    draft.timeZone = id
                } label: {
                    if draft.timeZone == id { Label(TimeZoneOption.label(id), systemImage: "checkmark") } else { Text(TimeZoneOption.label(id)) }
                }
            }
        } label: {
            rowLabel("globe", "時區", TimeZoneOption.label(draft.timeZone), highlight: false)
        }
    }

    // MARK: 持續時間

    var durationTab: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "sun.max").font(.system(size: 19)).foregroundStyle(Palette.textBody).frame(width: 26)
                    Text("全天").txt(17).foregroundStyle(Palette.text)
                    Spacer()
                    Toggle("全天", isOn: Binding(get: { draft.allDay }, set: { on in
                        if on { draft.allDay = true } else { setStartTime(draft.start); if draft.end <= draft.start { draft.end = draft.start + 60 } }
                    }))
                    .labelsHidden().tint(accent.color)
                    .accessibilityIdentifier("allDayToggle")
                }
                .frame(minHeight: 56)
                divider
                if draft.allDay {
                    row("calendar", "開始", draft.day.map(DateText.full) ?? "未設定", key: "startDate", highlight: true)
                    if expanded == "startDate" {
                        MonthPicker(month: $month, selected: draft.day, today: today) { d in pickDay(d); expanded = nil }.padding(.bottom, 8)
                    }
                    divider
                    row("calendar.badge.checkmark", "結束", (draft.endDay ?? draft.day).map(DateText.full) ?? "未設定", key: "endDate", highlight: true)
                    if expanded == "endDate" {
                        MonthPicker(month: $endMonth, selected: draft.endDay ?? draft.day, today: today) { d in
                            if draft.day == nil { draft.day = d }
                            if let s = draft.day, d >= s { draft.endDay = d > s ? d : nil }
                            expanded = nil
                        }
                        .padding(.bottom, 8)
                    }
                } else {
                    row("play.circle", "開始", (draft.day.map(DateText.monthDay) ?? "") + " " + DateText.hm(draft.start), key: "start", highlight: true)
                    if expanded == "start" { wheel(minute: draft.start) { setStartTime($0) } }
                    divider
                    row("stop.circle", "結束", endText, key: "end", highlight: true)
                    if expanded == "end" {
                        wheel(minute: draft.end % 1440) { m in
                            var e = m
                            if e <= draft.start { e += 1440 }
                            draft.end = min(e, TimeBlockEditor.maxEnd)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .card(18, color: Palette.raised)

            if !draft.allDay {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach([(15, "15 分"), (30, "30 分"), (45, "45 分"), (60, "1 小時"), (90, "1.5 小時"), (120, "2 小時"), (180, "3 小時")], id: \.0) { d in
                            OptionChip(label: d.1, on: draft.end - draft.start == d.0, filled: true) {
                                draft.end = min(draft.start + d.0, TimeBlockEditor.maxEnd)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                HStack {
                    Text("總時長").txt(15).foregroundStyle(Palette.textMuted)
                    Spacer()
                    Text(draft.end > draft.start ? DateText.duration(draft.duration) : "時間點").txt(15, .semibold).foregroundStyle(Palette.text)
                }
                .padding(.horizontal, 4)
                Button {
                    if draft.day == nil { draft.day = today }
                    openTime()
                } label: {
                    Label("在時間軸上拖曳調整", systemImage: "rectangle.split.1x2")
                        .txt(15, .semibold).foregroundStyle(accent.text)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .card(14, color: Palette.raised)
                }
                .buttonStyle(.press)
                .accessibilityIdentifier("openTimeline")
            }
        }
    }

    var endText: String {
        guard let d = draft.day else { return DateText.hm(draft.end) }
        if draft.end <= draft.start { return "無" }
        return DateText.monthDay(d.adding(days: draft.end / 1440)) + " " + DateText.hm(draft.end)
    }

    func wheel(minute: Int, set: @escaping (Int) -> Void) -> some View {
        DatePicker("", selection: Binding(get: {
            (draft.day ?? today).date(minute: minute % 1440, in: .current)
        }, set: { d in
            set(Calendar.current.component(.hour, from: d) * 60 + Calendar.current.component(.minute, from: d))
        }), displayedComponents: .hourAndMinute)
        .datePickerStyle(.wheel)
        .labelsHidden()
        .environment(\.locale, Locale(identifier: "zh_TW"))
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipped()
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
