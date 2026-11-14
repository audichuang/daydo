import SwiftUI
import DayDoCore

/// 2a / 2b · Date grid with dots + the selected day's agenda (collapsible to
/// one week); 2c · event month with spanning bars and "+N".
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    @AppStorage("calendarMode") private var eventMode = false
    @AppStorage("calendarCollapsed") private var collapsed = false
    @State private var selected: LocalDay?
    @State private var month: LocalDay?
    @State private var memberFilter: String?
    @State private var projectFilter: String?
    @State private var tasks: [TodoTask] = []

    var sel: LocalDay { selected ?? model.today }
    var shownMonth: LocalDay { month ?? model.today.firstOfMonth }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 12) {
                    filters
                    if eventMode { eventMonth } else { dateGrid; agenda }
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)

            ScreenHeader {
                Button {
                    if !eventMode { withAnimation(.snappy) { collapsed.toggle() } }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(String(shownMonth.year)) 年 \(shownMonth.month) 月").txt(17, .bold).foregroundStyle(Palette.text)
                        if !eventMode {
                            Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textSecondary)
                                .rotationEffect(.degrees(collapsed ? 180 : 0))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(eventMode ? "月份" : (collapsed ? "展開整個月份" : "收合成單週"))
                .accessibilityIdentifier("calendarTitle")
            } trailing: {
                HeaderAction(systemName: "plus", label: "新增任務", tint: accent.text) {
                    model.composing = ComposeRequest(day: sel)
                }
                HeaderAction(systemName: eventMode ? "list.bullet.below.rectangle" : "calendar", label: eventMode ? "切換為日期格與議程" : "切換為事件月曆") {
                    withAnimation(.snappy) { eventMode.toggle() }
                }
            }
        }
        .task(id: CalReload(month: shownMonth, member: memberFilter, revision: model.revision)) { await load() }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            shift(v.translation.width < 0 ? 1 : -1)
        })
    }

    func shift(_ dir: Int) {
        withAnimation(.snappy) {
            if collapsed && !eventMode {
                selected = sel.adding(days: 7 * dir)
                month = selected!.firstOfMonth
            } else {
                month = shownMonth.adding(months: dir)
                if let s = selected, s.month != month!.month { selected = month }
            }
        }
    }

    func load() async {
        let days = MonthLayout.gridDays(for: shownMonth)
        let q = TaskQuery(from: days.first!, to: days.last!, includeCompleted: true, memberId: memberFilter)
        tasks = (try? await model.api.listTasks(q)) ?? []
    }

    var filtered: [TodoTask] {
        guard let projectFilter else { return tasks }
        return tasks.filter { $0.projectId == projectFilter }
    }

    // MARK: Filters

    var filters: some View {
        HStack(spacing: 6) {
            if model.members.count > 1 {
                chip("全部", on: memberFilter == nil, member: nil) { memberFilter = nil }
                ForEach(model.members) { m in
                    chip(m.isMe ? "我參與" : m.name, on: memberFilter == m.id, member: m) { memberFilter = m.id }
                }
            }
            Menu {
                Button("全部清單") { projectFilter = nil }
                ForEach(model.projects) { p in Button(p.name) { projectFilter = p.id } }
            } label: {
                HStack(spacing: 4) {
                    Text("清單：" + (model.project(projectFilter)?.name ?? "全部")).txt(13, .semibold)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Palette.textNav)
                .padding(.horizontal, 12).frame(height: 32)
                .overlay(Capsule().strokeBorder(Palette.separator))
            }
            Spacer()
        }
    }

    func chip(_ label: String, on: Bool, member: Member?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let member { AvatarStack(members: [member], size: 22) }
                Text(label).txt(13, .semibold)
            }
            .foregroundStyle(on ? Palette.background : Palette.textNav)
            .padding(.leading, member == nil ? 12 : 5).padding(.trailing, 12).frame(height: 32)
            .background(Capsule().fill(on ? Palette.text : .clear))
            .overlay(Capsule().strokeBorder(on ? Palette.text : Palette.separator))
        }
        .buttonStyle(.plain)
    }

    // MARK: 2a / 2b

    var dateGrid: some View {
        let days = MonthLayout.gridDays(for: shownMonth)
        let shown: [LocalDay] = collapsed ? {
            let start = sel.adding(days: -sel.weekday)
            return (0..<7).map { start.adding(days: $0) }
        }() : days
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { Text($0).txt(11).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(shown, id: \.self) { d in dayCell(d) }
            }
            Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
                Capsule().fill(Palette.handle).frame(width: 36, height: 4).frame(maxWidth: .infinity, minHeight: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "展開整個月份" : "收合成單週")
        }
        .padding(.horizontal, 6).padding(.top, 10)
        .card()
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            if v.translation.height < -30 && !collapsed { withAnimation(.snappy) { collapsed = true } }
            if v.translation.height > 30 && collapsed { withAnimation(.snappy) { collapsed = false } }
        })
    }

    func dayCell(_ d: LocalDay) -> some View {
        let isSel = d == sel, isToday = d == model.today, inMonth = d.month == shownMonth.month || collapsed
        var colors: [String] = []
        for t in filtered where t.schedule?.occurs(on: d) == true {
            let c = model.project(t.projectId)?.color ?? "#5B6461"
            if !colors.contains(c) { colors.append(c) }
        }
        return Button {
            withAnimation(.snappy) { selected = d; if d.month != shownMonth.month { month = d.firstOfMonth } }
        } label: {
            VStack(spacing: 3) {
                Text("\(d.day)")
                    .txt(15, isSel || isToday ? .bold : .medium)
                    .foregroundStyle(isSel ? accent.onAccent : (isToday ? accent.text : Color(hex: "#E6E9E8")))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isSel ? accent.color : .clear))
                    .overlay(Circle().strokeBorder(isSel ? accent.color : (isToday ? accent.text : .clear), lineWidth: 2))
                HStack(spacing: 3) {
                    ForEach(colors.prefix(3), id: \.self) { c in Circle().fill(Color(hex: c)).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(inMonth ? 1 : 0.38)
        .accessibilityLabel(DateText.full(d) + (colors.isEmpty ? "" : "，有項目"))
        .accessibilityAddTraits(isSel ? .isSelected : [])
    }

    var dayItems: [TodoTask] {
        TaskGrouping.sortForDay(filtered.filter { $0.schedule?.occurs(on: sel) == true })
    }

    var agenda: some View {
        let items = dayItems
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DateText.full(sel) + (sel == model.today ? "・今天" : "")).txt(16, .bold).foregroundStyle(Palette.text)
                Text("\(items.count) 項").txt(13).foregroundStyle(Palette.textTertiary)
            }
            .padding(.bottom, 8)
            if items.isEmpty {
                Button { model.composing = ComposeRequest(day: sel) } label: {
                    Text("這天沒有項目，點這裡新增").txt(14).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                AgendaRow(task: t, day: sel)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Palette.separator).frame(height: 1) } }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .card()
    }

    // MARK: 2c

    var eventMonth: some View {
        let layout = MonthLayout(month: shownMonth, tasks: filtered)
        let dayCount = filtered.filter { $0.schedule?.occurs(on: sel) == true }
        return VStack(spacing: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(LocalDay.weekdaySymbols, id: \.self) { Text($0).txt(11).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity) }
                }
                .padding(.bottom, 4)
                ForEach(Array(layout.weeks.enumerated()), id: \.offset) { i, w in
                    WeekRow(week: w, month: shownMonth, selected: sel, today: model.today) { d in
                        withAnimation(.snappy) { selected = d }
                    } open: { id in model.detailTaskId = id }
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Color(hex: "#1E2022")).frame(height: 1) } }
                }
            }
            HStack(spacing: 10) {
                ForEach(model.projects.filter { p in filtered.contains { $0.projectId == p.id } }) { p in
                    HStack(spacing: 4) { ListDot(color: p.color, size: 7); Text(p.name).txt(11).foregroundStyle(Palette.textTertiary) }
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            Button {
                withAnimation(.snappy) { eventMode = false; collapsed = true }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(DateText.full(sel) + "・\(dayCount.count) 項").txt(15, .bold).foregroundStyle(Palette.text)
                        Text(dayCount.isEmpty ? "沒有項目" : dayCount.map(\.title).joined(separator: "、")).txt(12).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Text("查看議程").txt(13, .semibold).foregroundStyle(accent.text)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .card()
            }
            .buttonStyle(.plain)
        }
    }
}

struct CalReload: Hashable { var month: LocalDay; var member: String?; var revision: Int }

struct AgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var task: TodoTask
    var day: LocalDay

    var body: some View {
        let project = model.project(task.projectId)
        Button { model.detailTaskId = task.id } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.listColor(project?.color)).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).txt(15, .bold).foregroundStyle(task.isCompleted ? Palette.done : Palette.text)
                        .strikethrough(task.isCompleted, color: Palette.done).lineLimit(2).multilineTextAlignment(.leading)
                    if !task.content.isEmpty {
                        Text(task.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").txt(13).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(timeText).txt(13, .semibold).foregroundStyle(timeColor)
                        if task.commentCount > 0 { Label("\(task.commentCount)", systemImage: "bubble.left").labelStyle(MetaLabel()) }
                        Spacer()
                        if let project, project.isShared { AvatarStack(members: model.members.filter { project.memberIds.contains($0.id) }) }
                        Text(project?.name ?? "").txt(13).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var timeText: String {
        if task.isCompleted { return "已完成" }
        guard let s = task.schedule else { return "" }
        return DateText.taskLine(s, on: day, today: model.today)
    }

    var timeColor: Color {
        if task.isCompleted { return Palette.done }
        return TaskGrouping.isOverdue(task, today: model.today) ? Palette.overdue : accent.text
    }
}

/// One week of the event month: day numbers on top, up to 3 bar lanes.
struct WeekRow: View {
    @Environment(\.accent) private var accent
    var week: MonthLayout.Week
    var month: LocalDay
    var selected: LocalDay
    var today: LocalDay
    var pick: (LocalDay) -> Void
    var open: (String) -> Void
    @Environment(AppModel.self) private var model

    let laneH: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let colW = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { i, d in
                        let isSel = d == selected, isToday = d == today
                        Button { pick(d) } label: {
                            VStack(spacing: 0) {
                                Text("\(d.day)")
                                    .font(.system(size: 12, weight: isSel || isToday ? .bold : .semibold))
                                    .foregroundStyle(isSel ? accent.onAccent : (isToday ? accent.text : Color(hex: "#E6E9E8")))
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(isSel ? accent.color : .clear))
                                    .overlay(Circle().strokeBorder(isToday && !isSel ? accent.text : .clear, lineWidth: 1.5))
                                    .padding(.top, 4)
                                Spacer()
                                if let n = week.overflow[i] {
                                    Text("+\(n) 項").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 3).padding(.bottom, 3)
                                }
                            }
                            .frame(width: colW, height: geo.size.height)
                            .background(isSel ? accent.color.opacity(0.12) : .clear)
                            .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(Color(hex: "#1E2022")).frame(width: 1) } }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(d.month == month.month ? 1 : 0.38)
                        .accessibilityLabel(DateText.full(d))
                    }
                }
                ForEach(Array(week.bars.enumerated()), id: \.offset) { _, bar in
                    let color = model.project(bar.task.projectId)?.color ?? "#5B6461"
                    let done = bar.task.isCompleted
                    Button { open(bar.task.id) } label: {
                        Text((bar.continues ? "‹ " : "") + bar.task.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(done ? Palette.done : mix(color))
                            .strikethrough(done)
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                            .frame(width: colW * CGFloat(bar.endColumn - bar.startColumn + 1) - 3, height: laneH - 2, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 3).fill(done ? Palette.separator : Color(hex: color).opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: colW * CGFloat(bar.startColumn) + 1.5, y: 30 + CGFloat(bar.lane) * laneH)
                }
            }
        }
        .frame(height: 30 + laneH * 3 + 16)
    }

    func mix(_ hex: String) -> Color {
        let c = UIColor(Color(hex: hex))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: r * 0.55 + 0.45, green: g * 0.55 + 0.45, blue: b * 0.55 + 0.45)
    }
}
