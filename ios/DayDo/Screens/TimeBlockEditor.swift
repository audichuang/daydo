import SwiftUI
import DayDoCore

/// 4c / 4d · Edit a time block on a day timeline: drag the block to move,
/// drag the handles to change start/end (5-minute steps). The timeline runs
/// to 隔日 02:00 so blocks can cross midnight.
struct TimeBlockEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var draft: DateDraft
    var title: String
    var excludeTaskId: String?
    var cancel: () -> Void
    var save: () -> Void

    @State private var s = 18 * 60
    @State private var e = 18 * 60 + 30
    @State private var others: [TodoTask] = []
    @State private var allDayTitles: [String] = []
    @State private var dragStart: (Int, Int)?
    @State private var moveStartHaptic = 0
    @State private var snapHaptic = 0
    @GestureState private var isMoving = false

    static let pxPerMinute: CGFloat = 1
    static let step = 5
    static let maxEnd = 26 * 60
    let top: CGFloat = 10

    var day: LocalDay { draft.day ?? model.today }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PillButton(title: "取消", action: cancel)
                Spacer()
                Text(DateText.full(day)).txt(15, .bold).foregroundStyle(Palette.text)
                Spacer()
                PillButton(title: "儲存", kind: .primary) {
                    draft.day = day
                    draft.allDay = false
                    draft.endDay = nil
                    draft.start = s
                    draft.end = e
                    draft.stampTimeZoneIfFloating(TimeZone.current.identifier)
                    save()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .frame(height: 68)

            summary
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }

            timeline
        }
        .sensoryFeedback(.impact(weight: .light), trigger: moveStartHaptic)
        .sensoryFeedback(.selection, trigger: snapHaptic)
        .onAppear {
            s = draft.allDay ? 9 * 60 : draft.start
            e = draft.allDay || draft.end <= draft.start ? s + 30 : draft.end
        }
        .task { await loadDay() }
    }

    var conflicts: Int {
        others.filter { o in
            guard let os = o.schedule?.startMinute, let oe = o.schedule?.endOffsetMinutes else { return false }
            let start = o.schedule!.startDay == day ? os : os - 1440
            let end = o.schedule!.startDay == day ? oe : oe - 1440
            return s < end && e > start
        }.count
    }

    var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DateText.hm(s) + " – " + (e >= 1440 ? "隔日 " : "") + DateText.hm(e))
                    .txt(26, .bold).foregroundStyle(accent.text)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text("共 " + DateText.duration(e - s)).txt(14).foregroundStyle(Palette.textMuted)
            }
            .accessibilityElement(children: .combine)
            if e > 1440 {
                Text("結束於 \(DateText.full(day.adding(days: 1)))（隔日）").txt(13, .semibold).foregroundStyle(Palette.conflict)
            }
            HStack(spacing: 8) {
                timeField("開始", minute: s) { v in
                    let len = e - s
                    s = v
                    e = min(v + len, Self.maxEnd)
                }
                timeField("結束", minute: e % 1440) { v in
                    var end = v
                    if end <= s { end += 1440 }
                    e = min(end, Self.maxEnd)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach([(15, "15 分"), (30, "30 分"), (45, "45 分"), (60, "1 小時"), (90, "1.5 小時"), (120, "2 小時")], id: \.0) { d in
                        let on = e - s == d.0
                        Button { e = TimeGridDrag.resizeEnd(start: s, end: s, deltaMinutes: Double(d.0), step: Self.step, maxEnd: Self.maxEnd) } label: {
                            Text(d.1).txt(12, .semibold)
                                .foregroundStyle(on ? accent.onAccent : Palette.textBody)
                                .padding(.horizontal, 11).frame(height: 30)
                                .background(Capsule().fill(on ? accent.color : Palette.chip))
                        }
                        .buttonStyle(.press)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            if !allDayTitles.isEmpty || conflicts > 0 {
                Text("\(allDayTitles.isEmpty ? "" : "全天：" + allDayTitles.joined(separator: "・"))\(Text(conflicts > 0 ? "　與 \(conflicts) 項重疊" : "").foregroundStyle(Palette.conflict))")
                    .txt(12).foregroundStyle(Palette.textSecondary).lineLimit(2)
            }
        }
    }

    func timeField(_ label: String, minute: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).txt(13).foregroundStyle(Palette.textSecondary)
            DatePicker(label, selection: Binding(get: {
                day.date(minute: minute % 1440, in: .current)
            }, set: { d in
                let m = Calendar.current.component(.hour, from: d) * 60 + Calendar.current.component(.minute, from: d)
                set(m)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_TW"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.raised))
    }

    var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0...26, id: \.self) { h in
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(h >= 24 ? Palette.overnightTint : .clear)
                                Rectangle().fill(Palette.gridLine).frame(height: 1)
                                Text((h >= 24 ? "隔日 " : "") + String(format: "%02d:00", h % 24))
                                    .font(.system(size: 11))
                                    .foregroundStyle(h >= 24 ? Palette.conflict : Palette.gridLabel)
                                    .padding(.horizontal, 2)
                                    .background(Palette.card)
                                    .offset(x: 10, y: -8)
                            }
                            .frame(height: 60)
                            .id(h)
                        }
                    }
                    .padding(.top, top)

                    GeometryReader { geo in
                        let laneW = (geo.size.width - 66) / 2
                        ForEach(Array(othersLaid.enumerated()), id: \.offset) { _, o in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.task.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textNav).lineLimit(1)
                                Text(DateText.range(o.task.schedule!)).font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .frame(width: laneW - 4, height: max(CGFloat(o.end - o.start), 18), alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.blockMuted))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.blockMutedBorder))
                            .clipped()
                            .offset(x: 56 + CGFloat(o.lane) * laneW, y: top + CGFloat(o.start))
                        }
                        block(width: geo.size.width - 66)
                            .offset(x: 56, y: top + CGFloat(s))
                    }
                }
                .frame(height: 27 * 60 + top + 20)
            }
            .onAppear { proxy.scrollTo(max(0, s / 60 - 2), anchor: .top) }
        }
    }

    func block(width: CGFloat) -> some View {
        let h = max(CGFloat(e - s), 20)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(accent.color.opacity(0.8))
            RoundedRectangle(cornerRadius: 10).strokeBorder(accent.color, lineWidth: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "新任務" : title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                if h > 34 {
                    Text(DateText.hm(s) + " – " + (e >= 1440 ? "隔日 " : "") + DateText.hm(e)).font(.system(size: 12)).opacity(0.85)
                }
            }
            .foregroundStyle(accent.onAccent)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: width, height: h)
        .scaleEffect(isMoving && !reduceMotion ? 1.02 : 1)
        .animation(Motion.press(reduceMotion), value: isMoving)
        .highPriorityGesture(moveGesture)
        .overlay(alignment: .top) { handle.offset(y: -12).highPriorityGesture(dragGesture(.start)).accessibilityLabel("拖曳調整開始時間").accessibilityValue(DateText.hm(s)) }
        .overlay(alignment: .bottom) { handle.offset(y: 12).highPriorityGesture(dragGesture(.end)).accessibilityLabel("拖曳調整結束時間").accessibilityValue(DateText.hm(e)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("正在編輯的時間區塊，可拖曳移動或調整起訖")
    }

    var handle: some View {
        Capsule().fill(.white).frame(width: 30, height: 6)
            .overlay(Capsule().stroke(accent.color, lineWidth: 2))
            .frame(width: 56, height: 24)
            .contentShape(Rectangle())
    }

    enum DragKind { case start, end }

    /// Moving the whole block requires a 0.3s long press so vertical timeline
    /// scrolling over the block does not accidentally reposition it.
    var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($isMoving) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if dragStart == nil {
                    dragStart = (s, e)
                    moveStartHaptic += 1
                }
                let (s0, e0) = dragStart!
                let moved = TimeGridDrag.move(
                    start: s0,
                    end: e0,
                    deltaMinutes: Double(drag.translation.height / Self.pxPerMinute),
                    step: Self.step,
                    maxEnd: Self.maxEnd
                )
                if moved.startMinute != s || moved.endMinute != e {
                    s = moved.startMinute
                    e = moved.endMinute
                    snapHaptic += 1
                }
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    func dragGesture(_ kind: DragKind) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if dragStart == nil { dragStart = (s, e) }
                let (s0, e0) = dragStart!
                let delta = Double(v.translation.height / Self.pxPerMinute)
                switch kind {
                case .start:
                    let ns = TimeGridDrag.resizeStart(start: s0, end: e0, deltaMinutes: delta, step: Self.step, maxEnd: Self.maxEnd)
                    if ns != s {
                        s = ns
                        snapHaptic += 1
                    }
                case .end:
                    let ne = TimeGridDrag.resizeEnd(start: s0, end: e0, deltaMinutes: delta, step: Self.step, maxEnd: Self.maxEnd)
                    if ne != e {
                        e = ne
                        snapHaptic += 1
                    }
                }
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    struct Laid { var task: TodoTask; var start: Int; var end: Int; var lane: Int }

    /// Other timed items of the day in two lanes (overlaps side by side).
    var othersLaid: [Laid] {
        var out: [Laid] = []
        for o in others {
            guard let sch = o.schedule, let os = sch.startMinute else { continue }
            let shift = sch.startDay == day ? 0 : -1440 * sch.startDay.days(until: day)
            let start = os + shift, end = (sch.endOffsetMinutes ?? os + 30) + shift
            guard end > 0 else { continue }
            let lane = out.contains { $0.lane == 0 && $0.start < end && $0.end > start } ? 1 : 0
            out.append(Laid(task: o, start: max(0, start), end: end, lane: lane))
        }
        return out
    }

    func loadDay() async {
        guard let list = try? await model.api.listTasks(TaskQuery(from: day, to: day.adding(days: 1))) else { return }
        let rest = list.filter { $0.id != excludeTaskId }
        others = rest.filter { !($0.schedule?.isAllDay ?? true) }.sorted { ($0.schedule!.startDay, $0.schedule!.startMinute!) < ($1.schedule!.startDay, $1.schedule!.startMinute!) }
        allDayTitles = rest.filter { $0.schedule?.isAllDay == true && $0.schedule!.occurs(on: day) }.map { t in
            if let (i, n) = t.schedule!.dayPosition(on: day) { return "\(t.title)（第 \(i)/\(n) 天）" }
            return t.title
        }
    }
}
