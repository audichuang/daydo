import SwiftUI
import DayDoCore

/// 週清單: 2-column x 4-row week agenda grid (cell 0 = mini month, cells 1..7 = Sun..Sat).
struct WeekAgendaGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    var weekDays: [LocalDay]
    var month: LocalDay
    var tasks: [TodoTask]
    var today: LocalDay
    var isRegular: Bool = false
    var showOwnerAvatars: Bool = false
    var isViewerFilter: Bool = false
    var openTask: (String) -> Void
    var tapEmpty: (LocalDay) -> Void
    var openDay: (LocalDay) -> Void
    var pickMiniDay: (LocalDay) -> Void

    var body: some View {
        GeometryReader { geo in
            let hPad: CGFloat = isRegular ? 16 : 8
            let topPad: CGFloat = 4
            let bottomPad: CGFloat = isRegular ? 96 : 170
            let gridW = max(0, geo.size.width - hPad * 2)
            let gridH = max(0, geo.size.height - topPad - bottomPad)
            let colW = max(0, (gridW - 1) / 2)
            let rowH = max(0, (gridH - 5) / 4)

            VStack(spacing: 0) {
                dividerLine(horizontal: true)
                HStack(spacing: 0) {
                    miniMonthCell(width: colW, height: rowH)
                    dividerLine(horizontal: false)
                    if let sun = weekDays.first {
                        dayCell(sun, width: colW, height: rowH)
                    } else {
                        Color.clear.frame(width: colW, height: rowH)
                    }
                }
                ForEach(0..<3, id: \.self) { row in
                    dividerLine(horizontal: true)
                    HStack(spacing: 0) {
                        let leftIdx = 1 + row * 2
                        let rightIdx = leftIdx + 1
                        if leftIdx < weekDays.count {
                            dayCell(weekDays[leftIdx], width: colW, height: rowH)
                        } else {
                            Color.clear.frame(width: colW, height: rowH)
                        }
                        dividerLine(horizontal: false)
                        if rightIdx < weekDays.count {
                            dayCell(weekDays[rightIdx], width: colW, height: rowH)
                        } else {
                            Color.clear.frame(width: colW, height: rowH)
                        }
                    }
                }
                dividerLine(horizontal: true)
            }
            .frame(width: gridW, height: gridH, alignment: .topLeading)
            .padding(.horizontal, hPad)
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weekAgenda")
    }

    private func dividerLine(horizontal: Bool) -> some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
    }

    // MARK: Mini Month (Cell 0)

    private func miniMonthCell(width: CGFloat, height: CGFloat) -> some View {
        let gridDays = MonthLayout.gridDays(for: month)
        let weeks = stride(from: 0, to: gridDays.count, by: 7).map { Array(gridDays[$0..<min($0 + 7, gridDays.count)]) }
        let displayedWeekStart = weekDays.first
        let circleSize: CGFloat = isRegular ? 22 : 17
        let dayFontSize: CGFloat = isRegular ? 12 : 10.5

        return VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: isRegular ? 11 : 10, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: isRegular ? 15 : 13)

            VStack(spacing: 1) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    let isDisplayedWeek = week.first == displayedWeekStart
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { d in
                            let isToday = d == today
                            let inMonth = d.month == month.month
                            Button { pickMiniDay(d) } label: {
                                Text("\(d.day)")
                                    .font(.system(size: dayFontSize, weight: isToday ? .bold : (isDisplayedWeek ? .semibold : .regular)))
                                    .monospacedDigit()
                                    .foregroundStyle(isToday ? accent.onAccent : (isDisplayedWeek ? accent.text : Palette.textDay))
                                    .frame(width: circleSize, height: circleSize)
                                    .background(Circle().fill(isToday ? accent.color : .clear))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
                            .hoverEffect(.highlight)
                            .opacity(inMonth ? 1 : (isDisplayedWeek ? 0.65 : 0.35))
                            .accessibilityIdentifier("weekAgendaMini-\(d)")
                            .accessibilityLabel(DateText.full(d))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Capsule().fill(isDisplayedWeek ? accent.soft : .clear))
                }
            }
        }
        .padding(.horizontal, isRegular ? 10 : 6)
        .padding(.vertical, 6)
        .frame(width: width, height: height, alignment: .top)
        .clipped()
    }

    // MARK: Day Cell (Cells 1..7)

    private func tasksForDay(_ d: LocalDay) -> [TodoTask] {
        let items = tasks.filter { $0.schedule?.occurs(on: d) == true }
        let active = TaskGrouping.sortForDay(items.filter { !model.displaysCompleted($0) })
        let done = TaskGrouping.sortForDay(items.filter { model.displaysCompleted($0) })
        return active + done
    }

    private func dayCell(_ d: LocalDay, width: CGFloat, height: CGFloat) -> some View {
        let isToday = d == today
        let headerH: CGFloat = isRegular ? 24 : 22
        let itemH: CGFloat = isRegular ? 22 : 19
        let itemSpacing: CGFloat = 2
        let listH = max(0, height - 6 - headerH - 4 - 4)
        let maxSlots = max(0, Int((listH + itemSpacing) / (itemH + itemSpacing)))

        let dayTasks = tasksForDay(d)
        let hasOverflow = dayTasks.count > maxSlots
        let visibleCount = hasOverflow ? max(0, maxSlots - 1) : dayTasks.count
        let visibleTasks = Array(dayTasks.prefix(visibleCount))
        let overflowCount = dayTasks.count - visibleCount

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { tapEmpty(d) }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(DateText.full(d))，點兩下新增任務")
                .accessibilityHidden(isViewerFilter)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("週\(LocalDay.weekdaySymbols[d.weekday])")
                        .font(.system(size: isRegular ? 13 : 12, weight: isToday ? .bold : .semibold))
                        .foregroundStyle(isToday ? accent.text : Palette.textSecondary)
                    Text("\(d.day)")
                        .font(.system(size: isRegular ? 13 : 12, weight: isToday ? .bold : .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? accent.onAccent : Palette.text)
                        .frame(width: isToday ? (isRegular ? 22 : 20) : nil, height: isToday ? (isRegular ? 22 : 20) : nil)
                        .background {
                            if isToday {
                                Circle().fill(accent.color)
                            }
                        }
                    Spacer(minLength: 0)
                }
                .frame(height: headerH)
                .padding(.bottom, 4)
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: itemSpacing) {
                    ForEach(visibleTasks) { task in
                        taskRow(task, cellWidth: width - (isRegular ? 20 : 12), rowHeight: itemH)
                    }
                    if hasOverflow {
                        Button { openDay(d) } label: {
                            Text("+\(overflowCount)")
                                .font(.system(size: isRegular ? 12 : 11, weight: .semibold))
                                .foregroundStyle(accent.text)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: itemH)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.press(scale: 0.96, opacity: 0.85))
                        .hoverEffect(.highlight)
                        .accessibilityIdentifier("weekAgendaMore-\(d)")
                        .accessibilityLabel("還有 \(overflowCount) 項任務，點按切換至單日檢視")
                    }
                }
            }
            .padding(.horizontal, isRegular ? 10 : 6)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weekAgendaDay-\(d)")
    }

    private func taskRow(_ task: TodoTask, cellWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let color = Palette.listColor(model.project(task.projectId)?.color)
        let isDone = model.displaysCompleted(task)
        let owner = partnerOwner(for: task, show: showOwnerAvatars, members: model.members)
        let startMinute = task.schedule?.startMinute
        let avatarSize: CGFloat = isRegular ? 15 : 13
        let strokeWidth: CGFloat = 1
        let timeWidth: CGFloat = startMinute == nil ? 0 : (isRegular ? 36 : 33)
        let availableTitleWidth = cellWidth - 2.5 - 4 - 4 - timeWidth - (avatarSize + strokeWidth + 4)
        let showAvatar = owner != nil && availableTitleWidth >= TimeGrid.ownerAvatarMinTitleWidth

        return Button { openTask(task.id) } label: {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(color)
                    .frame(width: 2.5)
                Text(task.title)
                    .font(.system(size: isRegular ? 13 : 11.5, weight: .medium))
                    .foregroundStyle(isDone ? Palette.done : Palette.text)
                    .strikethrough(isDone, color: Palette.done)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                if showAvatar, let owner {
                    OwnerAvatarBadge(member: owner, size: avatarSize, strokeWidth: strokeWidth)
                }
                if let m = startMinute {
                    Text(DateText.hm(m))
                        .font(.system(size: isRegular ? 11 : 10, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(isDone ? Palette.done : Palette.textSecondary)
                        .fixedSize()
                }
            }
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(isDone ? 0.08 : 0.16)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(isDone ? 0.75 : 1)
        }
        .buttonStyle(.press(scale: 0.97, opacity: 0.88))
        .hoverEffect(.highlight)
        .accessibilityLabel(taskAccessibilityLabel(task, isDone: isDone))
        .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
    }

    private func taskAccessibilityLabel(_ task: TodoTask, isDone: Bool) -> String {
        var parts = [task.title]
        if let m = task.schedule?.startMinute {
            parts.append(DateText.hm(m))
        }
        if isDone {
            parts.append("已完成")
        }
        return parts.joined(separator: "，")
    }
}
