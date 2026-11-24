import Observation
import SwiftUI
import DayDoCore

/// Scroll target for a time-grid hour row. A distinct type so it can never match the
/// Int offsets other ForEach rows in the same ScrollView use (0...6 for the week columns).
struct HourRowID: Hashable { var hour: Int }

struct PendingBlockMove {
    var token: UUID
    var taskId: String
    var schedule: Schedule
}

@MainActor
final class GridDragLock {
    var isActive = false
}

/// 週／3日／日 time grid with an all-day strip, overlapping blocks side by
/// side, a now line on today, and tap/long-press-drag interactions.
struct TimeGrid: View {
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    var days: [LocalDay]
    var tasks: [TodoTask]
    var allDayItems: [CalendarProjection.TimeGridAllDayItem]
    var blocksByDay: [[DayLayout.Block]]
    var today: LocalDay
    var selected: LocalDay
    var isRegular: Bool = false
    var isActive: Bool = true
    var scrollResetToken: Int = 0
    var showOwnerAvatars: Bool = false
    var isViewerFilter: Bool = false
    var dragLock: GridDragLock
    var openTask: (String) -> Void
    var tapSlot: (LocalDay, Int) -> Void
    var createRange: (LocalDay, Int, Int) -> Void
    var moveTask: (TodoTask, DateDraft) -> Void
    var tapDay: (LocalDay) -> Void

    @State private var dragMode: DragMode?
    @State private var moveStartHaptic = 0
    @State private var snapHaptic = 0
    @State private var suppressTapUntil: ContinuousClock.Instant?

    private enum DragMode {
        case move(task: TodoTask, sourceColumnDay: LocalDay, anchorPoint: CGPoint, targetColumnIndex: Int, moveResult: TimeGridDrag.MoveResult)
        case create(day: LocalDay, columnIndex: Int, anchorY: CGFloat, range: TimeGridDrag.RangeResult)
    }

    private var draggedTaskId: String? {
        if case .move(let task, _, _, _, _) = dragMode { return task.id }
        return nil
    }

    private var isTapSuppressed: Bool {
        guard let until = suppressTapUntil else { return false }
        return ContinuousClock.now < until
    }

    var hourH: CGFloat { Platform.isMac ? 52 : (isRegular ? 64 : 56) }
    var gutter: CGFloat { isRegular ? 52 : 40 }

    var body: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - gutter - 8) / CGFloat(days.count)
            VStack(spacing: 0) {
                if Platform.isMac {
                    HStack(spacing: 0) {
                        Spacer().frame(width: gutter)
                        ForEach(days, id: \.self) { d in
                            let isToday = d == today
                            Button { tapDay(d) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("週\(LocalDay.weekdaySymbols[d.weekday])")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Palette.textTertiary)
                                        .lineLimit(1)
                                    Text("\(d.day)")
                                        .font(.system(size: 13, weight: isToday ? .semibold : .medium))
                                        .foregroundStyle(isToday ? accent.onAccent : Palette.text)
                                        .frame(width: 22, height: 22, alignment: isToday ? .center : .leading)
                                        .background(Circle().fill(isToday ? accent.color : .clear))
                                }
                                .padding(.leading, 8)
                                .padding(.vertical, 4)
                                .frame(width: colW, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.press(scale: 0.96, opacity: 0.88))
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Palette.gridColumnLine).frame(width: 1)
                            }
                            .accessibilityLabel(DateText.full(d))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Palette.separator).frame(height: 1)
                    }
                } else {
                    HStack(spacing: 0) {
                        Spacer().frame(width: gutter)
                        ForEach(days, id: \.self) { d in
                            Button { tapDay(d) } label: {
                                VStack(spacing: 2) {
                                    Text(LocalDay.weekdaySymbols[d.weekday]).font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                                    Text("\(d.day)").font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(d == today ? accent.onAccent : Palette.text)
                                        .frame(width: 30, height: 30)
                                        .background(Circle().fill(d == today ? accent.color : .clear))
                                }
                                .frame(width: colW)
                            }
                            .buttonStyle(.press(scale: 0.94, opacity: 0.88))
                            .accessibilityLabel(DateText.full(d))
                        }
                    }
                    .padding(.bottom, 4)
                }

                let ad = allDayItems
                let isDay = days.count == 1
                let totalLanes = (ad.map(\.lane).max() ?? -1) + 1
                let maxVisibleLanes = isDay ? 4 : 3
                let laneCount = min(maxVisibleLanes, totalLanes)
                let overflowByCol: [Int: Int] = {
                    guard !isDay else { return [:] }
                    var counts: [Int: Int] = [:]
                    for item in ad where item.lane >= maxVisibleLanes {
                        for col in item.firstColumn...item.lastColumn { counts[col, default: 0] += 1 }
                    }
                    return counts
                }()
                if laneCount > 0 {
                    if isDay {
                        let visibleHeight = CGFloat(laneCount) * 21 + 6
                        HStack(alignment: .top, spacing: 0) {
                            Text("全天")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textFaint)
                                .padding(.trailing, Platform.isMac ? 8 : 0)
                                .frame(width: gutter, alignment: Platform.isMac ? .trailing : .center)
                                .padding(.top, 4)
                            ScrollView(.vertical, showsIndicators: totalLanes > maxVisibleLanes) {
                                ZStack(alignment: .topLeading) {
                                    ForEach(Array(ad.enumerated()), id: \.offset) { _, item in
                                        allDayChip(item.task, width: colW * CGFloat(item.lastColumn - item.firstColumn + 1) - 3)
                                            .offset(x: colW * CGFloat(item.firstColumn) + 1.5, y: CGFloat(item.lane) * 21 + 2)
                                    }
                                }
                                .frame(width: colW, height: CGFloat(totalLanes) * 21 + 4, alignment: .topLeading)
                                .enclosingScrollsToTop(false)
                            }
                            .frame(height: visibleHeight)
                        }
                        .frame(height: visibleHeight, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
                    } else {
                        ZStack(alignment: .topLeading) {
                            Text("全天")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textFaint)
                                .padding(.trailing, Platform.isMac ? 8 : 0)
                                .frame(width: gutter, alignment: Platform.isMac ? .trailing : .center)
                                .padding(.top, 4)
                            ForEach(Array(ad.filter { $0.lane < maxVisibleLanes }.enumerated()), id: \.offset) { _, item in
                                allDayChip(item.task, width: colW * CGFloat(item.lastColumn - item.firstColumn + 1) - 3)
                                    .offset(x: gutter + colW * CGFloat(item.firstColumn) + 1.5, y: CGFloat(item.lane) * 21 + 2)
                            }
                            ForEach(overflowByCol.keys.sorted(), id: \.self) { col in
                                let n = overflowByCol[col]!
                                Button { tapDay(days[col]) } label: {
                                    Text("+\(n)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(accent.text)
                                        .frame(width: colW - 3, height: 16, alignment: .leading)
                                        .padding(.leading, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .offset(x: gutter + colW * CGFloat(col) + 1.5, y: CGFloat(laneCount) * 21 + 2)
                                .accessibilityLabel("還有 \(n) 項全天任務，點按切換至單日檢視")
                            }
                        }
                        .frame(height: CGFloat(laneCount) * 21 + (overflowByCol.isEmpty ? 6 : 20), alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(0..<25, id: \.self) { h in
                                    HStack(alignment: .top, spacing: 0) {
                                        if Platform.isMac {
                                            Text(h == 24 ? "00:00" : String(format: "%02d:00", h))
                                                .font(.system(size: 11))
                                                .monospacedDigit()
                                                .foregroundStyle(Palette.textTertiary)
                                                .padding(.trailing, 8)
                                                .frame(width: gutter, alignment: .trailing)
                                                .offset(y: -6)
                                        } else {
                                            Text(h == 24 ? "00" : String(format: "%02d", h)).font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                                                .frame(width: gutter, alignment: .center).offset(y: -7)
                                        }
                                        Rectangle().fill(Palette.gridLine).frame(height: 1)
                                    }
                                    .frame(height: h == 24 ? 1 : hourH, alignment: .top)
                                    .id(HourRowID(hour: h))
                                }
                            }
                            // Column separators + tap-to-create
                            HStack(spacing: 0) {
                                Spacer().frame(width: gutter)
                                ForEach(days, id: \.self) { d in
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .frame(width: colW, height: hourH * 24)
                                        .overlay(alignment: .leading) { Rectangle().fill(Palette.gridColumnLine).frame(width: 1) }
                                        .allowsHitTesting(dragMode == nil)
                                        .onTapGesture(coordinateSpace: .local) { p in
                                            guard dragMode == nil, !isTapSuppressed else { return }
                                            let m = Int(p.y / hourH * 60) / 30 * 30
                                            tapSlot(d, min(m, 23 * 60 + 30))
                                        }
                                        .accessibilityLabel("\(DateText.full(d)) 空白時段，點兩下新增")
                                }
                            }
                            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                                let dayBlocks = i < blocksByDay.count ? blocksByDay[i] : []
                                ForEach(dayBlocks, id: \.self) { b in
                                    block(b, colW: colW)
                                        .opacity(draggedTaskId == b.task.id ? 0.35 : 1)
                                        .allowsHitTesting(dragMode == nil)
                                        .offset(x: gutter + colW * CGFloat(i) + colW / CGFloat(b.lanes) * CGFloat(b.lane) + 1, y: CGFloat(b.start) / 60 * hourH)
                                }
                                if d == today { nowLine(colW: colW).offset(x: gutter + colW * CGFloat(i), y: nowY - 4) }
                            }
                            if let dragMode {
                                dragPreview(dragMode, colW: colW)
                            }
                        }
                        .frame(height: hourH * 24 + 10, alignment: .topLeading)
                        .gesture(
                            TimeGridLongPressGesture(
                                dragLock: dragLock,
                                shouldBegin: { point in canBeginDrag(at: point, colW: colW) },
                                onBegan: { point in beginDrag(at: point, colW: colW) },
                                onChanged: { point in updateDrag(at: point, colW: colW) },
                                onEnded: { point in endDrag(at: point, colW: colW) },
                                onCancelled: { cancelDrag() }
                            )
                        )
                        .padding(.top, 8)
                        .padding(.bottom, isRegular ? 24 : 160)
                        .enclosingScrollsToTop(isActive)
                    }
                    .accessibilityIdentifier("timeGridScroll")
                    .scrollDisabled(dragMode != nil)
                    .defaultScrollAnchor(UnitPoint(x: 0, y: min(1, CGFloat(initialHour) * hourH / 900)), for: .initialOffset)
                    .scrollIndicators(.hidden)
                    .task(id: TimeGridScrollKey(days: days, resetToken: scrollResetToken)) {
                        guard isActive else { return }
                        // Wait for menu dismiss / transition & initial layout, then snap accurately.
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(HourRowID(hour: initialHour), anchor: .top)
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: moveStartHaptic)
        .sensoryFeedback(.selection, trigger: snapHaptic)
        .onChange(of: isActive) { _, active in
            if !active { cancelDrag() }
        }
        .onDisappear { cancelDrag() }
    }

    var initialHour: Int {
        max(0, (days.contains(today) ? nowMinute / 60 : 8) - 2)
    }

    var nowMinute: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = model.timeZone
        let c = cal.dateComponents([.hour, .minute], from: model.now)
        return c.hour! * 60 + c.minute!
    }
    var nowY: CGFloat { CGFloat(nowMinute) / 60 * hourH }

    /// Title width kept (~4 CJK characters) before an owner avatar may take
    /// room in timed blocks and all-day chips: narrow cells drop the avatar
    /// (VoiceOver still reads the owner) rather than truncating titles such as
    /// 學校接小安／學校接小明 to the same prefix.
    static let ownerAvatarMinTitleWidth: CGFloat = 56
    /// Width budget for the Mac single-line `[HH:MM] ` time prefix at 12pt medium.

    func allDayChip(_ t: TodoTask, width: CGFloat) -> some View {
        let color = Palette.listColor(model.project(t.projectId)?.color)
        let owner = partnerOwner(for: t, show: showOwnerAvatars, members: model.members)
        // Same title-first rule as timed blocks: color bar 2 + leading 4 + title
        // + trailing 2 + avatar 14 + stroke 1 + trailing 3.
        let showAvatar = owner != nil && width >= 2 + 4 + Self.ownerAvatarMinTitleWidth + 2 + 14 + 1 + 3
        return Button(action: { openTask(t.id) }) {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 2)
                Text(t.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(t.isCompleted ? Palette.done : Palette.text)
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .padding(.trailing, showAvatar ? 2 : 4)
                Spacer(minLength: 0)
                if showAvatar, let owner {
                    OwnerAvatarBadge(member: owner, size: 14, strokeWidth: 1)
                        .opacity(t.isCompleted ? 0.75 : 1)
                        .padding(.trailing, 3)
                }
            }
            .frame(width: width, height: 19)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.28)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.press(scale: 0.96, opacity: 0.88))
        .macTaskContextMenu(t)
        .hoverEffect(.highlight)
        .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
    }

    func nowLine(colW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().fill(Palette.overdue).frame(width: 8, height: 8)
            Rectangle().fill(Palette.overdue).frame(width: colW - 8, height: 1.5)
        }
        .allowsHitTesting(false)
    }

    func block(_ b: DayLayout.Block, colW: CGFloat) -> some View {
        let color = Palette.listColor(model.project(b.task.projectId)?.color)
        let w = colW / CGFloat(b.lanes) - 2
        let h = max(CGFloat(b.end - b.start) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
        let done = b.task.isCompleted
        let owner = partnerOwner(for: b.task, show: showOwnerAvatars, members: model.members)
        return blockContent(task: b.task, schedule: b.task.schedule, color: color, owner: owner, width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(done ? 0.12 : 0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .onTapGesture {
                guard dragMode == nil, !isTapSuppressed else { return }
                openTask(b.task.id)
            }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(b.task.title + "，" + (b.task.schedule.map { DateText.range($0) } ?? ""))
        .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
        .macTaskContextMenu(b.task)
    }

    private func blockContent(task: TodoTask, schedule: Schedule?, color: Color, owner: Member?, width w: CGFloat, height h: CGFloat) -> some View {
        let done = task.isCompleted
        let avatarSize: CGFloat = (w >= 84 && h >= 32) ? 16 : 14
        let strokeWidth: CGFloat = 1
        let topInset: CGFloat = h >= 24 ? 3 : 2
        let neededWidth: CGFloat = 3 + 4 + Self.ownerAvatarMinTitleWidth + 4 + avatarSize + strokeWidth + 4
        let neededHeight: CGFloat = avatarSize + strokeWidth + topInset
        let showAvatar = owner != nil && w >= neededWidth && h >= neededHeight
        return HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if Platform.isMac {
                    let showRange = h >= 36 && schedule?.startMinute != nil
                    // Title only: a "[HH:MM]" prefix crowded out titles of side-by-side blocks and showed the wrong day on cross-midnight continuations.
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(done ? Palette.done : Palette.text)
                        .strikethrough(done)
                        .lineLimit(1)
                    if showRange, let s = schedule {
                        Text(DateText.range(s, separator: "-"))
                            .font(.system(size: 11, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(task.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(done ? Palette.done : Palette.text)
                        .strikethrough(done).lineLimit(h > 40 ? 3 : 1).multilineTextAlignment(.leading)
                    if h > 34, let s = schedule { Text(DateText.range(s)).font(.system(size: 10)).foregroundStyle(Palette.textSecondary).lineLimit(1) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, h >= 24 ? 3 : 2)
            Spacer(minLength: 0)
            if showAvatar, let owner {
                OwnerAvatarBadge(member: owner, size: avatarSize, strokeWidth: strokeWidth)
                    .opacity(done ? 0.75 : 1)
                    .padding(.top, topInset)
                    .padding(.trailing, 4)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    // MARK: Drag & Drop

    private func hitBlock(at point: CGPoint, colW: CGFloat) -> TimeGridDrag.BlockHit? {
        TimeGridDrag.hitTestBlock(
            x: Double(point.x),
            y: Double(point.y),
            days: days,
            tasks: tasks,
            gutter: Double(gutter),
            columnWidth: Double(colW),
            hourHeight: Double(hourH)
        )
    }

    private func canBeginDrag(at point: CGPoint, colW: CGFloat) -> Bool {
        guard colW > 0, !days.isEmpty else { return false }
        guard point.x >= gutter, point.x < gutter + colW * CGFloat(days.count),
              point.y >= 0, point.y <= hourH * 24 else { return false }
        if let hit = hitBlock(at: point, colW: colW) {
            return !model.isViewer(projectId: hit.block.task.projectId)
        }
        return !isViewerFilter
    }

    private func beginDrag(at point: CGPoint, colW: CGFloat) {
        guard canBeginDrag(at: point, colW: colW) else {
            dragLock.isActive = false
            return
        }
        if let hit = hitBlock(at: point, colW: colW),
           let schedule = hit.block.task.schedule,
           let moveResult = TimeGridDrag.moveSchedule(schedule, sourceColumnDay: hit.day, targetColumnDay: hit.day, minuteDelta: 0) {
            dragMode = .move(
                task: hit.block.task,
                sourceColumnDay: hit.day,
                anchorPoint: point,
                targetColumnIndex: hit.columnIndex,
                moveResult: moveResult
            )
            moveStartHaptic += 1
        } else {
            let colIdx = TimeGridDrag.columnIndex(x: Double(point.x), gutter: Double(gutter), columnWidth: Double(colW), columnCount: days.count)
            let range = TimeGridDrag.createRange(anchorY: Double(point.y), currentY: Double(point.y), hourHeight: Double(hourH))
            dragMode = .create(day: days[colIdx], columnIndex: colIdx, anchorY: point.y, range: range)
            moveStartHaptic += 1
        }
    }

    private func updateDrag(at point: CGPoint, colW: CGFloat) {
        guard let current = dragMode else { return }
        switch current {
        case .move(let task, let sourceDay, let anchor, let prevColIdx, let prevMove):
            guard let schedule = task.schedule else { return }
            let targetColIdx = TimeGridDrag.columnIndex(x: Double(point.x), gutter: Double(gutter), columnWidth: Double(colW), columnCount: days.count)
            let minuteDelta = TimeGridDrag.snappedMinuteDelta(dy: Double(point.y - anchor.y), hourHeight: Double(hourH))
            guard let nextMove = TimeGridDrag.moveSchedule(schedule, sourceColumnDay: sourceDay, targetColumnDay: days[targetColIdx], minuteDelta: minuteDelta) else { return }
            if targetColIdx != prevColIdx || nextMove != prevMove {
                snapHaptic += 1
                dragMode = .move(task: task, sourceColumnDay: sourceDay, anchorPoint: anchor, targetColumnIndex: targetColIdx, moveResult: nextMove)
            }
        case .create(let day, let colIdx, let anchorY, let prevRange):
            let nextRange = TimeGridDrag.createRange(anchorY: Double(anchorY), currentY: Double(point.y), hourHeight: Double(hourH))
            if nextRange != prevRange {
                snapHaptic += 1
                dragMode = .create(day: day, columnIndex: colIdx, anchorY: anchorY, range: nextRange)
            }
        }
    }

    private func endDrag(at point: CGPoint, colW: CGFloat) {
        updateDrag(at: point, colW: colW)
        let finished = dragMode
        dragMode = nil
        suppressTapUntil = ContinuousClock.now + .milliseconds(150)
        switch finished {
        case .move(let task, _, _, _, let moveResult):
            moveTask(task, moveResult.applied(to: task))
        case .create(let day, _, _, let range):
            createRange(day, range.startMinute, range.endMinute)
        case nil:
            break
        }
    }

    private func cancelDrag() {
        dragLock.isActive = false
        dragMode = nil
    }

    @ViewBuilder
    private func dragPreview(_ mode: DragMode, colW: CGFloat) -> some View {
        switch mode {
        case .move(let task, _, _, let targetColIdx, let moveResult):
            if let previewSchedule = moveResult.applied(to: task).schedule {
                let previewTask: TodoTask = {
                    var copy = task
                    copy.schedule = previewSchedule
                    return copy
                }()
                let color = Palette.listColor(model.project(task.projectId)?.color)
                let owner = partnerOwner(for: task, show: showOwnerAvatars, members: model.members)
                let segments: [(Int, DayLayout.Block)] = days.enumerated().flatMap { colIdx, d in
                    DayLayout.blocks(for: [previewTask], on: d).map { (colIdx, $0) }
                }
                let primarySegment = segments.first(where: { $0.0 == targetColIdx }) ?? segments.first
                ZStack(alignment: .topLeading) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, entry in
                        let (colIdx, seg) = entry
                        let w = colW - 2
                        let h = max(CGFloat(seg.end - seg.start) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
                        let x = gutter + colW * CGFloat(colIdx) + 1
                        let y = CGFloat(seg.start) / 60 * hourH
                        blockContent(task: previewTask, schedule: previewSchedule, color: color, owner: owner, width: w, height: h)
                            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.42)))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: Palette.navShadow, radius: 6, y: 3)
                            .scaleEffect(reduceMotion ? 1 : 1.03)
                            .animation(reduceMotion ? nil : Motion.press(reduceMotion), value: moveResult)
                            .offset(x: x, y: y)
                    }
                    if let (colIdx, seg) = primarySegment {
                        let w = colW - 2
                        let h = max(CGFloat(seg.end - seg.start) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
                        let x = gutter + colW * CGFloat(colIdx) + 1
                        let y = CGFloat(seg.start) / 60 * hourH
                        previewTimePill(DateText.range(previewSchedule), blockX: x, blockY: y, blockW: w, blockH: h, colW: colW)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

        case .create(_, let colIdx, _, let range):
            let x = gutter + colW * CGFloat(colIdx) + 1
            let y = CGFloat(range.startMinute) / 60 * hourH
            let w = colW - 2
            let h = max(CGFloat(range.endMinute - range.startMinute) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
            let timeText = DateText.hm(range.startMinute) + " – " + (range.endMinute >= 1440 ? "隔日 " : "") + DateText.hm(range.endMinute)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("新任務").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent.text).lineLimit(1)
                    if h > 34 {
                        Text(timeText).font(.system(size: 10)).foregroundStyle(accent.text.opacity(0.85)).lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, h >= 24 ? 3 : 2)
                .frame(width: w, height: h, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 4).fill(accent.color.opacity(0.24)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.color, lineWidth: 1.5))
                .scaleEffect(reduceMotion ? 1 : 1.02)
                .animation(reduceMotion ? nil : Motion.press(reduceMotion), value: range)
                .offset(x: x, y: y)

                previewTimePill(timeText, blockX: x, blockY: y, blockW: w, blockH: h, colW: colW)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func previewTimePill(_ text: String, blockX: CGFloat, blockY: CGFloat, blockW: CGFloat, blockH: CGFloat, colW: CGFloat) -> some View {
        let estWidth: CGFloat = 96
        let maxX = max(gutter, gutter + colW * CGFloat(days.count) - estWidth)
        let pillX = max(gutter, min(maxX, blockX + blockW / 2 - estWidth / 2))
        let pillY = blockY >= 26 ? blockY - 24 : blockY + blockH + 4
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.card))
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: Palette.navShadow, radius: 4, y: 2)
            .fixedSize()
            .offset(x: pillX, y: pillY)
    }
}

/// UIKit long-press recognizer (0.3s) for dragging blocks and creating ranges
/// on `TimeGrid`, disabling enclosing scroll panning immediately upon activation.
struct TimeGridLongPressGesture: UIGestureRecognizerRepresentable {
    var dragLock: GridDragLock
    var shouldBegin: (CGPoint) -> Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(
            converter: converter,
            dragLock: dragLock,
            shouldBegin: shouldBegin,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let lp = UILongPressGestureRecognizer()
        lp.minimumPressDuration = 0.3
        lp.allowableMovement = 10
        lp.delegate = context.coordinator
        return lp
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.converter = context.converter
        context.coordinator.dragLock = dragLock
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = context.converter.localLocation
        switch recognizer.state {
        case .began:
            context.coordinator.lockScroll(for: recognizer.view)
            onBegan(point)
        case .changed:
            onChanged(point)
        case .ended:
            context.coordinator.unlockScroll()
            onEnded(point)
        case .cancelled, .failed:
            context.coordinator.unlockScroll()
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var converter: CoordinateSpaceConverter
        var dragLock: GridDragLock
        var shouldBegin: (CGPoint) -> Bool
        var onBegan: (CGPoint) -> Void
        var onChanged: (CGPoint) -> Void
        var onEnded: (CGPoint) -> Void
        var onCancelled: () -> Void
        private weak var lockedPan: UIPanGestureRecognizer?

        init(
            converter: CoordinateSpaceConverter,
            dragLock: GridDragLock,
            shouldBegin: @escaping (CGPoint) -> Bool,
            onBegan: @escaping (CGPoint) -> Void,
            onChanged: @escaping (CGPoint) -> Void,
            onEnded: @escaping (CGPoint) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.converter = converter
            self.dragLock = dragLock
            self.shouldBegin = shouldBegin
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let point = converter.convert(globalPoint: gestureRecognizer.location(in: nil), to: .local)
            return shouldBegin(point)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        func lockScroll(for view: UIView?) {
            dragLock.isActive = true
            if let scrollView = view?.enclosingScrollView {
                lockedPan = scrollView.panGestureRecognizer
                scrollView.panGestureRecognizer.isEnabled = false
            }
        }

        func unlockScroll() {
            dragLock.isActive = false
            lockedPan?.isEnabled = true
            lockedPan = nil
        }
    }
}
