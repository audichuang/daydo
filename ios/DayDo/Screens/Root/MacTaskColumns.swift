import SwiftUI
import UIKit
import DayDoCore

extension EnvironmentValues {
    /// Mac only: shows/hides the list sidebar from the list column's own top bar (the
    /// navigation bar that hosted the system toggle is hidden on Mac).
    @Entry var macSidebarToggle: (() -> Void)? = nil
}

/// Mac tasks tab content: list (or kanban) taking the free width, detail pane on the right
/// with a draggable divider. List mode keeps the pane open with a placeholder, like a
/// desktop mail/todo app; kanban opens it only for a selected card.
struct MacTaskColumns: View {
    @Environment(AppModel.self) private var model
    var showsPlaceholder: Bool
    @AppStorage("macDetailWidth") private var detailWidth: Double = 420
    @State private var dragStart: Double?

    static let minDetail: Double = 320
    static let maxDetail: Double = 720
    static let minList: Double = 360

    var body: some View {
        GeometryReader { geo in
            let maxForWindow = max(Self.minDetail, min(Self.maxDetail, geo.size.width - Self.minList))
            let width = min(max(detailWidth, Self.minDetail), maxForWindow)
            HStack(spacing: 0) {
                TaskListScreen(scope: model.scope)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsPlaceholder || model.selectedTaskId != nil {
                    divider(maxForWindow: maxForWindow)
                    Group {
                        if let taskId = model.selectedTaskId {
                            TaskDetailContent(taskId: taskId, isInline: true, showCloseButton: !showsPlaceholder) {
                                model.selectedTaskId = nil
                            }
                            .id(taskId)
                        } else {
                            TaskDetailEmptyState()
                        }
                    }
                    .frame(width: width)
                }
            }
        }
    }

    private func divider(maxForWindow: Double) -> some View {
        Rectangle().fill(Palette.separator).frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = dragStart ?? detailWidth
                        if dragStart == nil { dragStart = start }
                        detailWidth = min(max(start - v.translation.width, Self.minDetail), maxForWindow)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityHidden(true)
            .ignoresSafeArea()
    }
}
