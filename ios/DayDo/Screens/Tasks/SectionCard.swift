import SwiftUI
import UniformTypeIdentifiers
import DayDoCore

struct SectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var section: TaskSection
    var scope: TaskScope
    var closed: Bool
    var toggle: () -> Void

    var titleColor: Color {
        switch section.kind {
        case .overdue: Palette.overdue
        case .completed, .trash: Palette.textSecondary
        default: Palette.text
        }
    }

    var isViewerScope: Bool {
        if case .project(let id) = scope { return model.isViewer(projectId: id) }
        return false
    }

    /// Inside a single list the title already names it; rows skip the list label.
    var isProjectScope: Bool {
        switch scope {
        case .project, .smart(.inbox): return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(section.title).txt(15, .bold).foregroundStyle(titleColor)
                    Spacer()
                    if section.kind == .overdue,
                       !isViewerScope,
                       !model.editableTaskIds(in: section.tasks).isEmpty {
                        Button("全部延到今天") {
                            model.postponeOverdue(tasks: section.tasks)
                        }
                        .txt(13, .semibold).foregroundStyle(accent.text).padding(.trailing, 6).buttonStyle(.press)
                        .hoverEffect(.highlight)
                    }
                    Text("\(section.tasks.count)")
                        .txt(13)
                        .foregroundStyle(Palette.textTertiary)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(closed ? -90 : 0))
                }
                .padding(.leading, Platform.isMac ? 12 : 16).padding(.trailing, Platform.isMac ? 12 : 14)
                .frame(minHeight: Platform.isMac ? 34 : 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.99, opacity: 0.92))
            .hoverEffect(.highlight)
            .accessibilityValue(closed ? "已收合" : "已展開")

            if !closed {
                let firstId = section.tasks.first?.id
                LazyVStack(spacing: 0) {
                    ForEach(section.tasks) { t in
                        TaskRow(
                            task: t,
                            separator: t.id != firstId,
                            sectionKind: section.kind,
                            sectionId: section.id,
                            inTrash: scope == .smart(.trash),
                            selectsInline: true,
                            showProject: !isProjectScope
                        )
                        .id(TaskRowSelection(sectionId: section.id, taskId: t.id))
                        .transition(Motion.rowTransition(reduceMotion))
                    }
                }
                .transition(Motion.expandTransition(reduceMotion))
            }
        }
        .card(Platform.isMac ? 12 : 16)
        .clipShape(RoundedRectangle(cornerRadius: Platform.isMac ? 12 : 16, style: .continuous))
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    var scope: TaskScope

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: scope == .smart(.trash) ? "trash" : "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.textFaint)
            Text(message).txt(15).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .card()
    }

    var message: String {
        switch scope {
        case .smart(.today): Platform.isMac ? "今天沒有待辦。在上方輸入框新增一項。" : "今天沒有待辦。按右下角 ＋ 新增一項。"
        case .smart(.trash): "垃圾桶是空的"
        case .smart(.completed): "還沒有完成的任務"
        default: "這裡還沒有任務"
        }
    }
}
