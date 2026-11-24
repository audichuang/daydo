import SwiftUI
import DayDoCore

/// 週清單: 2-column x 4-row week agenda grid (cell 0 = mini month, cells 1..7 = Sun..Sat).
struct WeekAgendaGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.textScale) private var textScale

    var weekDays: [LocalDay]
    var month: LocalDay
    var selected: LocalDay
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

        let hPad: CGFloat = isRegular ? 10 : 6
        let vPad: CGFloat = height < 105 ? 3 : 6
        let innerH = max(0, height - vPad * 2)
        let headerH = min((isRegular ? 15 : 13) * textScale, max(10, innerH * 0.14))
        let headerGap: CGFloat = height < 105 ? 1 : 2
        let weekCount = max(1, weeks.count)
        let rowGap: CGFloat = height < 105 ? 0 : 1
        let weekAvailH = max(0, innerH - headerH - headerGap - rowGap * CGFloat(weekCount - 1))
        let weekRowH = weekAvailH / CGFloat(weekCount)
        let colCellW = max(0, (width - hPad * 2) / 7)
        let circleSize = min((isRegular ? 22 : 18) * textScale, max(10, min(weekRowH, colCellW) * 0.92))
        let dayFontSize = min((isRegular ? 12 : 11) * textScale, max(8, circleSize * 0.64))
        let weekdayFontSize = min((isRegular ? 11 : 10) * textScale, max(8, headerH * 0.78))

        return VStack(spacing: headerGap) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: weekdayFontSize, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: headerH)

            VStack(spacing: rowGap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    let isDisplayedWeek = week.first == displayedWeekStart
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { d in
                            let isToday = d == today
                            let isSelected = d == selected
                            let inMonth = d.month == month.month
                            Button { pickMiniDay(d) } label: {
                                Text("\(d.day)")
                                    .font(.system(size: dayFontSize, weight: (isToday || isSelected) ? .bold : (isDisplayedWeek ? .semibold : .regular)))
                                    .monospacedDigit()
                                    .foregroundStyle(isToday ? accent.onAccent : (isDisplayedWeek ? accent.text : Palette.textDay))
                                    .frame(width: circleSize, height: circleSize)
                                    .background {
                                        if isToday {
                                            Circle().fill(accent.color)
                                        } else if isSelected {
                                            Circle().strokeBorder(accent.color, lineWidth: 1.5)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
                            .hoverEffect(.highlight)
                            .opacity(inMonth ? 1 : (isDisplayedWeek ? 0.65 : 0.35))
                            .accessibilityIdentifier("weekAgendaMini-\(d)")
                            .accessibilityLabel(isToday ? "\(DateText.full(d))，今天" : DateText.full(d))
                            .accessibilityValue(isDisplayedWeek ? "目前顯示的週" : "")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: weekRowH)
                    .background(Capsule().fill(isDisplayedWeek ? accent.soft : .clear))
                }
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .frame(width: width, height: height, alignment: .top)
        .clipped()
    }

    // MARK: Day Cell (Cells 1..7)

    @ViewBuilder
    private func emptyDayTapTarget(_ d: LocalDay) -> some View {
        if isViewerFilter {
            Color.clear.accessibilityHidden(true)
        } else {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { tapEmpty(d) }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(DateText.full(d))，點兩下新增任務")
                .accessibilityAction { tapEmpty(d) }
        }
    }

    private func overflowButton(_ d: LocalDay, count: Int, height: CGFloat, fontSize: CGFloat, alignment: Alignment) -> some View {
        Button { openDay(d) } label: {
            Text("+\(count)")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(accent.text)
                .padding(.horizontal, 4)
                .frame(maxWidth: alignment == .leading ? .infinity : nil, alignment: alignment)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press(scale: 0.96, opacity: 0.85))
        .hoverEffect(.highlight)
        .accessibilityIdentifier("weekAgendaMore-\(d)")
        .accessibilityLabel("還有 \(count) 項任務，點按切換至單日檢視")
    }

    private func dayCell(_ d: LocalDay, width: CGFloat, height: CGFloat) -> some View {
        let isToday = d == today
        let isSelected = d == selected
        let hPad: CGFloat = isRegular ? 10 : 6
        let vPadTop: CGFloat = height < 105 ? 3 : 6
        let vPadBot: CGFloat = height < 105 ? 2 : 4
        let headerGap: CGFloat = height < 105 ? 2 : 4
        let headerFontSize: CGFloat = (isRegular ? 13 : 12) * textScale
        let todayCircleSize: CGFloat = (isRegular ? 22 : 20) * textScale
        let headerH: CGFloat = max((isRegular ? 24 : 22) * textScale, todayCircleSize)
        let itemH: CGFloat = (isRegular ? 22 : 19) * textScale
        let moreFontSize: CGFloat = (isRegular ? 12 : 11) * textScale
        let itemSpacing: CGFloat = 2
        let listH = max(0, height - vPadTop - headerH - headerGap - vPadBot)
        let maxSlots = max(0, Int((listH + itemSpacing) / (itemH + itemSpacing)))

        let dayTasks = TaskGrouping.calendarDayTasks(tasks, on: d)
        let hasOverflow = dayTasks.count > maxSlots
        let visibleCount = hasOverflow ? max(0, maxSlots - 1) : dayTasks.count
        let visibleTasks = Array(dayTasks.prefix(visibleCount))
        let overflowCount = dayTasks.count - visibleCount
        let inlineOverflowInHeader = hasOverflow && maxSlots == 0

        return ZStack(alignment: .topLeading) {
            emptyDayTapTarget(d)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("週\(LocalDay.weekdaySymbols[d.weekday])")
                            .font(.system(size: headerFontSize, weight: isToday ? .bold : .semibold))
                            .foregroundStyle(isToday ? accent.text : Palette.textSecondary)
                        Text("\(d.day)")
                            .font(.system(size: headerFontSize, weight: isToday ? .bold : .semibold))
                            .monospacedDigit()
                            .foregroundStyle(isToday ? accent.onAccent : Palette.text)
                            .frame(width: isToday ? todayCircleSize : nil, height: isToday ? todayCircleSize : nil)
                            .background {
                                if isToday {
                                    Circle().fill(accent.color)
                                }
                            }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(isToday ? "\(DateText.full(d))，今天" : DateText.full(d))
                    .allowsHitTesting(false)

                    Spacer(minLength: 0)

                    if inlineOverflowInHeader {
                        overflowButton(d, count: overflowCount, height: headerH, fontSize: moreFontSize, alignment: .trailing)
                    }
                }
                .frame(height: headerH)
                .padding(.bottom, headerGap)

                if !visibleTasks.isEmpty || (hasOverflow && !inlineOverflowInHeader) {
                    VStack(alignment: .leading, spacing: itemSpacing) {
                        ForEach(visibleTasks) { task in
                            taskRow(task, on: d, cellWidth: width - hPad * 2, rowHeight: itemH)
                        }
                        if hasOverflow && !inlineOverflowInHeader {
                            overflowButton(d, count: overflowCount, height: itemH, fontSize: moreFontSize, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.top, vPadTop)
            .padding(.bottom, vPadBot)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weekAgendaDay-\(d)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func taskRow(_ task: TodoTask, on day: LocalDay, cellWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let color = Palette.listColor(model.project(task.projectId)?.color)
        let isDone = model.displaysCompleted(task)
        let owner = partnerOwner(for: task, show: showOwnerAvatars, members: model.members)
        let startMinute = task.schedule.flatMap { DayLayout.clippedRange(for: $0, on: day)?.start }
        let titleFontSize: CGFloat = (isRegular ? 13 : 11.5) * textScale
        let timeFontSize: CGFloat = (isRegular ? 11 : 10) * textScale
        let avatarSize: CGFloat = min(rowHeight - 4, (isRegular ? 15 : 13) * textScale)
        let strokeWidth: CGFloat = 1
        let timeWidth: CGFloat = startMinute == nil ? 0 : (isRegular ? 36 : 33) * textScale
        let availableTitleWidth = cellWidth - 2.5 - 4 - 4 - timeWidth - (avatarSize + strokeWidth + 4)
        let showAvatar = owner != nil && availableTitleWidth >= TimeGrid.ownerAvatarMinTitleWidth

        return Button(action: { openTask(task.id) }) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(color)
                    .frame(width: 2.5)
                Text(task.title)
                    .font(.system(size: titleFontSize, weight: .medium))
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
                        .font(.system(size: timeFontSize, weight: .regular))
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
        .macTaskContextMenu(task)
        .hoverEffect(.highlight)
        .accessibilityLabel(taskAccessibilityLabel(task, startMinute: startMinute, isDone: isDone))
        .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
    }

    private func taskAccessibilityLabel(_ task: TodoTask, startMinute: Int?, isDone: Bool) -> String {
        var parts = [task.title]
        if let m = startMinute {
            parts.append(DateText.hm(m))
        }
        if isDone {
            parts.append("已完成")
        }
        return parts.joined(separator: "，")
    }
}
