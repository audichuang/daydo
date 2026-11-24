import Observation
import SwiftUI
import DayDoCore

struct CalendarTaskPopoverTarget: Equatable {
    let id = UUID()
    var taskId: String
    /// Frame in the host window's coordinate space, sampled at click time.
    var rect: CGRect
}

final class AnchorViewBox {
    weak var view: UIView?

    @MainActor
    func windowFrame() -> CGRect {
        guard let view, let window = view.window else { return .zero }
        return view.convert(view.bounds, to: window)
    }
}

struct AnchorFrameProbe: UIViewRepresentable {
    let box: AnchorViewBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        box.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        box.view = uiView
    }
}

/// Button wrapper that reads its window frame at click time on Mac so a
/// single `UIPopoverPresentationController` can anchor to the clicked task
/// without writing `@State` on every scroll frame.
struct CalendarTaskAnchorButton<Label: View>: View {
    var action: (CGRect) -> Void
    @ViewBuilder var label: () -> Label
    @State private var anchorBox = AnchorViewBox()

    var body: some View {
        Button {
            action(Platform.isMac ? anchorBox.windowFrame() : .zero)
        } label: {
            label()
        }
        .background {
            if Platform.isMac {
                AnchorFrameProbe(box: anchorBox)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct CalendarTaskTapAnchor<Content: View>: View {
    var onTap: (CGRect) -> Void
    @ViewBuilder var content: () -> Content
    @State private var anchorBox = AnchorViewBox()

    var body: some View {
        content()
            .onTapGesture {
                onTap(Platform.isMac ? anchorBox.windowFrame() : .zero)
            }
            .background {
                if Platform.isMac {
                    AnchorFrameProbe(box: anchorBox)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// Presents `CalendarTaskPopoverCard` via `UIPopoverPresentationController` anchored
/// to the clicked task's window frame.
struct CalendarPopoverPresenter: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.textScale) private var textScale
    @Binding var target: CalendarTaskPopoverTarget?
    var tasks: [TodoTask]
    var onOpenDetail: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        coord.model = model
        coord.onDismiss = {
            if self.target != nil {
                self.target = nil
            }
        }
        model.registerCalendarPopoverDismisser { [weak coord] completion in
            guard let coord else {
                completion()
                return
            }
            coord.dismiss(animated: true, completion: completion)
        }

        guard let target else {
            if coord.presentedController != nil {
                coord.dismiss(animated: true)
            }
            return
        }

        if coord.presentedId == target.id { return }

        let taskId = target.taskId
        let initialTask = tasks.first { $0.id == taskId }
        let card = CalendarTaskPopoverCard(
            taskId: taskId,
            initialTask: initialTask,
            onOpen: {
                coord.dismiss(animated: true) {
                    onOpenDetail(taskId)
                }
            },
            onDismiss: {
                coord.dismiss(animated: true)
            }
        )
        .environment(model)
        .environment(\.accent, accent)
        .environment(\.textScale, textScale)

        let presentNew: () -> Void = {
            guard self.target?.id == target.id else { return }
            guard !model.hasActiveRootSheet,
                  let host = uiView.nearestViewController ?? uiView.window?.rootViewController,
                  host.presentedViewController == nil else {
                coord.dismiss(animated: false)
                return
            }
            let hc = UIHostingController(rootView: card)
            hc.sizingOptions = .preferredContentSize
            hc.modalPresentationStyle = .popover
            hc.view.backgroundColor = .clear
            let fitted = hc.sizeThatFits(in: CGSize(width: 280, height: 600))
            hc.preferredContentSize = CGSize(width: max(280, fitted.width), height: max(120, fitted.height))
            if let popover = hc.popoverPresentationController {
                popover.sourceView = uiView
                let raw: CGRect
                if target.rect.isEmpty {
                    raw = .zero
                } else if let window = uiView.window {
                    raw = uiView.convert(target.rect, from: window)
                } else {
                    raw = target.rect
                }
                let clamped = raw.isEmpty
                    ? CGRect(x: uiView.bounds.midX, y: uiView.bounds.midY, width: 1, height: 1)
                    : raw.intersection(uiView.bounds)
                popover.sourceRect = clamped.isEmpty
                    ? CGRect(x: uiView.bounds.midX, y: uiView.bounds.midY, width: 1, height: 1)
                    : clamped
                popover.permittedArrowDirections = [.left, .right, .up, .down]
                popover.delegate = coord
            }
            coord.presentedController = hc
            coord.presentedId = target.id
            model.isCalendarPopoverPresented = true
            host.present(hc, animated: true)
        }

        if let existing = coord.presentedController {
            coord.presentedController = nil
            coord.presentedId = nil
            existing.dismiss(animated: false) {
                presentNew()
            }
        } else {
            DispatchQueue.main.async {
                presentNew()
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        let model = coordinator.model
        model?.registerCalendarPopoverDismisser(nil)
        coordinator.dismiss(animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        weak var model: AppModel?
        weak var presentedController: UIViewController?
        var presentedId: UUID?
        var onDismiss: (() -> Void)?

        func dismiss(animated: Bool = true, completion: (@MainActor () -> Void)? = nil) {
            let presented = presentedController
            presentedController = nil
            presentedId = nil
            onDismiss?()
            if model?.isCalendarPopoverPresented == true {
                model?.isCalendarPopoverPresented = false
            }
            guard let presented else {
                completion?()
                return
            }
            if presented.isBeingDismissed {
                if let transition = presented.transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { _ in
                        Task { @MainActor in completion?() }
                    }
                } else {
                    DispatchQueue.main.async {
                        completion?()
                    }
                }
            } else if presented.presentingViewController != nil {
                presented.dismiss(animated: animated) {
                    Task { @MainActor in completion?() }
                }
            } else {
                completion?()
            }
        }

        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
            .none
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            presentedController = nil
            presentedId = nil
            model?.isCalendarPopoverPresented = false
            onDismiss?()
        }
    }
}

struct CalendarTaskPopoverCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var taskId: String
    var initialTask: TodoTask?
    var onOpen: () -> Void
    var onDismiss: () -> Void

    @State private var loadedTask: TodoTask?

    private var task: TodoTask? { loadedTask ?? initialTask }

    var body: some View {
        Group {
            if let task {
                let isDone = model.displaysCompleted(task)
                let readOnly = model.isViewer(projectId: task.projectId)
                let project = model.project(task.projectId)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Button { model.toggleComplete(task) } label: {
                            TaskCheckbox(done: isDone, priority: task.priority, size: 18)
                                .padding(.top, 2)
                                .frame(width: 24, height: 24, alignment: .top)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.press(scale: 0.9, opacity: 0.85))
                        .disabled(readOnly)
                        .accessibilityLabel((isDone ? "取消完成：" : "完成：") + task.title)

                        Text(task.title)
                            .txt(16, .semibold)
                            .foregroundStyle(isDone ? Palette.done : Palette.text)
                            .strikethrough(isDone, color: Palette.done)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .animation(Motion.check(reduceMotion), value: isDone)

                    VStack(alignment: .leading, spacing: 6) {
                        if let scheduleText = dateSummary(task) {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 12))
                                    .foregroundStyle(dateColor(task))
                                Text(scheduleText)
                                    .txt(13, .medium)
                                    .foregroundStyle(dateColor(task))
                                    .lineLimit(1)
                                if task.repeat != nil {
                                    Image(systemName: "repeat")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        }
                        if let project {
                            HStack(spacing: 6) {
                                ListDot(color: project.color, size: 8)
                                Text(project.name)
                                    .txt(13)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 34)

                    Rectangle().fill(Palette.separatorSoft).frame(height: 1)

                    HStack {
                        Spacer()
                        Button("開啟") {
                            onOpen()
                        }
                        .txt(13, .semibold)
                        .foregroundStyle(accent.text)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(accent.soft))
                        .buttonStyle(.press)
                        .accessibilityIdentifier("calendarPopover.open")
                    }
                }
                .padding(14)
            } else {
                ProgressView()
                    .tint(Palette.textSecondary)
                    .padding(24)
            }
        }
        .frame(width: 280)
        .background(Palette.card)
        .task(id: model.revision) {
            do {
                let fresh = try await model.api.getTask(id: taskId)
                if fresh.deletedAt != nil {
                    onDismiss()
                } else {
                    loadedTask = fresh
                }
            } catch is CancellationError {
                return
            } catch {
                onDismiss()
            }
        }
    }

    private func dateSummary(_ task: TodoTask) -> String? {
        guard let s = task.schedule else { return nil }
        let day = DateText.relative(s.startDay, today: model.today)
        if s.isAllDay {
            if s.isMultiDay { return "\(DateText.monthDay(s.startDay)) – \(DateText.monthDay(s.lastDay))・全天" }
            return day + "・全天"
        }
        return day + " " + DateText.range(s)
    }

    private func dateColor(_ task: TodoTask) -> Color {
        guard task.schedule != nil else { return Palette.textSecondary }
        return TaskGrouping.isOverdue(task, today: model.today) ? Palette.overdue : accent.text
    }
}
