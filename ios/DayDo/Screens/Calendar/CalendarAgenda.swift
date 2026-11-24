import Observation
import SwiftUI
import DayDoCore

func partnerOwner(for task: TodoTask, show: Bool, members: [Member]) -> Member? {
    guard show, !task.ownerId.isEmpty,
          let member = members.first(where: { $0.id == task.ownerId }),
          !member.isMe else { return nil }
    return member
}

struct OwnerAvatarBadge: View {
    var member: Member
    var size: CGFloat = 18
    var strokeWidth: CGFloat = 1.5

    var body: some View {
        AvatarView(member: member, size: size)
            .overlay(Circle().stroke(Palette.card, lineWidth: strokeWidth))
            .accessibilityHidden(true)
    }
}

/// Card-style agenda row with a checkbox (清單 view).
struct AgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var task: TodoTask
    var day: LocalDay
    var showOwnerAvatar = false
    var showProject = true
    var onOpen: (String) -> Void

    private var isDone: Bool {
        model.displaysCompleted(task)
    }

    var body: some View {
        let project = model.project(task.projectId)
        let owner = partnerOwner(for: task, show: showOwnerAvatar, members: model.members)
        HStack(alignment: .top, spacing: 12) {
            Button { toggle() } label: {
                TaskCheckbox(done: isDone, priority: task.priority, size: 22).frame(width: 32, height: 34)
            }
            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
            .hoverEffect(.highlight)
            .disabled(model.isViewer(projectId: task.projectId))
            .accessibilityLabel((isDone ? "取消完成：" : "完成：") + task.title)
            Button {
                onOpen(task.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(task.title).txt(17, .medium).foregroundStyle(isDone ? Palette.done : Palette.text)
                            .strikethrough(isDone, color: Palette.done).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let owner {
                            OwnerAvatarBadge(member: owner)
                                .padding(.top, 2)
                        }
                    }
                    if !task.content.isEmpty {
                        Text(task.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(DateText.agendaLine(task, includeDay: task.schedule?.isMultiDay ?? false)).txt(14, .medium).foregroundStyle(AgendaText.color(task, today: model.today, accent: accent))
                        Spacer(minLength: 4)
                        if showProject {
                            Text(project?.name ?? "").txt(14).foregroundStyle(Palette.textTertiary).lineLimit(1)
                        }
                    }
                }
                .opacity(isDone ? 0.75 : 1)
                .animation(Motion.check(reduceMotion), value: isDone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.985, opacity: 0.95, highlight: Palette.pressHighlightStrong))
            .hoverEffect(.highlight)
            .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
        }
        .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, Platform.isMac ? 8 : 12)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.listColor(project?.color)).frame(width: 4) }
    }

    func toggle() {
        model.toggleComplete(task)
    }
}

/// Timeline-style agenda row: date/time on the left, a connector, the card.
struct TimelineAgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var task: TodoTask
    var day: LocalDay
    var last: Bool
    var showOwnerAvatar = false
    var onOpen: (String) -> Void

    var body: some View {
        let owner = partnerOwner(for: task, show: showOwnerAvatar, members: model.members)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                if let m = task.schedule.flatMap({ DayLayout.clippedRange(for: $0, on: day)?.start }) {
                    Text(DateText.hm(m)).font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.top, 12)
            VStack(spacing: 0) {
                Circle().strokeBorder(Palette.textSecondary, lineWidth: 1.5).frame(width: 14, height: 14).padding(.top, 16)
                if !last { Rectangle().fill(Palette.separator).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            .frame(width: 14)
            Button {
                onOpen(task.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(DateText.agendaLine(task, includeDay: task.schedule?.isMultiDay ?? false))
                            .txt(15, .medium).foregroundStyle(AgendaText.color(task, today: model.today, accent: accent))
                        Spacer(minLength: 0)
                        if let owner {
                            OwnerAvatarBadge(member: owner)
                                .opacity(task.isCompleted ? 0.75 : 1)
                        }
                    }
                    Text(task.title).txt(17, .medium).foregroundStyle(task.isCompleted ? Palette.done : Palette.text)
                        .strikethrough(task.isCompleted, color: Palette.done).multilineTextAlignment(.leading)
                    if !task.content.isEmpty {
                        Text(task.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .card(14)
            }
            .buttonStyle(.press(scale: 0.98, opacity: 0.92))
            .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
            .padding(.bottom, 12)
        }
    }
}

enum AgendaText {
    static func color(_ t: TodoTask, today: LocalDay, accent: AccentTheme) -> Color {
        if t.isCompleted { return Palette.done }
        return TaskGrouping.isOverdue(t, today: today) ? Palette.overdue : accent.text
    }
}
