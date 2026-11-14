import SwiftUI
import DayDoCore

/// Quick add: title first, then date / priority / list in one row of chips.
/// "詳細設定" creates the task and opens the full detail sheet.
struct ComposerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    var request: ComposeRequest

    @State private var title = ""
    @State private var note = ""
    @State private var day: LocalDay?
    @State private var priority: Priority = .none
    @State private var projectId: String?
    @State private var showPicker = false
    @State private var pickerMonth = LocalDay(year: 2000, month: 1, day: 1)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PillButton(title: "取消") { dismiss() }
                Spacer()
                Text("新增任務").txt(15, .bold).foregroundStyle(Palette.text)
                Spacer()
                PillButton(title: "新增", kind: canSave ? .primary : .disabled) { save(openDetail: false) }
            }
            TextField("想做什麼？", text: $title, axis: .vertical)
                .txt(20, .bold)
                .foregroundStyle(Palette.text)
                .focused($focused)
                .accessibilityIdentifier("composerTitle")
                .lineLimit(1...3)
                .submitLabel(.done)
                .onSubmit { if canSave { save(openDetail: false) } }
            TextField("描述（選填）", text: $note, axis: .vertical)
                .txt(15)
                .foregroundStyle(Palette.textBody)
                .lineLimit(1...4)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    OptionChip(label: "今天", on: day == model.today) { day = model.today }
                    OptionChip(label: "明天", on: day == model.today.adding(days: 1)) { day = model.today.adding(days: 1) }
                    OptionChip(label: otherDayLabel, on: day != nil && day != model.today && day != model.today.adding(days: 1)) {
                        pickerMonth = (day ?? model.today).firstOfMonth
                        withAnimation(.snappy) { showPicker.toggle() }
                    }
                    OptionChip(label: "無日期", on: day == nil) { day = nil }
                }
            }
            .scrollIndicators(.hidden)

            if showPicker {
                MonthPicker(month: $pickerMonth, selected: day, today: model.today) { d in
                    day = d
                    withAnimation(.snappy) { showPicker = false }
                }
                .padding(8)
                .card(16, color: Palette.raised)
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach([Priority.high, .medium, .low, .none], id: \.self) { p in
                        Button(p.label + "優先") { priority = p }
                    }
                } label: {
                    Label(priority == .none ? "優先級" : priority.label, systemImage: "flag.fill")
                        .txt(13, .semibold)
                        .foregroundStyle(priority == .none ? Palette.textNav : Palette.priority(priority))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(Palette.chip))
                }
                Menu {
                    ForEach(model.projects) { p in Button(p.name) { projectId = p.id } }
                } label: {
                    HStack(spacing: 6) {
                        ListDot(color: model.project(projectId)?.color, size: 8)
                        Text(model.project(projectId)?.name ?? "收件匣").txt(13, .semibold)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Palette.textNav)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(Palette.chip))
                }
                Spacer()
                Button("詳細設定") { save(openDetail: true) }
                    .txt(13, .semibold)
                    .foregroundStyle(canSave ? accent.text : Palette.textFaint)
                    .disabled(!canSave)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.card)
        .presentationCornerRadius(28)
        .onAppear {
            day = request.day
            projectId = request.projectId ?? model.inbox?.id
            focused = true
        }
    }

    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var otherDayLabel: String {
        if let day, day != model.today, day != model.today.adding(days: 1) { return DateText.monthDay(day) }
        return "選擇日期…"
    }

    func save(openDetail: Bool) {
        let input = CreateTaskInput(projectId: projectId, title: title, content: note, priority: priority,
                                    schedule: day.map { Schedule.allDay($0) }, tags: request.tag.map { [$0] })
        Task {
            if let t = await model.perform({ try await $0.createTask(input) }) {
                dismiss()
                if openDetail {
                    try? await Task.sleep(for: .milliseconds(350))
                    model.detailTaskId = t.id
                }
            }
        }
    }
}
