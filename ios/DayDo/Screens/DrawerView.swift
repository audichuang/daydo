import SwiftUI
import DayDoCore

/// 1a · Left list drawer: smart lists, folders (expandable), loose lists,
/// tags, and 已完成／垃圾桶 at the bottom.
struct DrawerOverlay: View {
    @Environment(AppModel.self) private var model
    @Binding var open: Bool
    @State private var drag: CGFloat = 0
    @State private var rowDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.82, 340)
            ZStack(alignment: .leading) {
                Color.black.opacity(open ? 0.45 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .allowsHitTesting(open)
                    .accessibilityLabel("關閉抽屜")
                if open {
                DrawerView(close: close, rowDragging: $rowDragging)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Palette.card.ignoresSafeArea())
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28, style: .continuous))
                    .ignoresSafeArea(edges: .bottom)
                    .offset(x: min(0, drag))
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onChanged { v in
                                guard !rowDragging else { return }
                                if abs(v.translation.width) > abs(v.translation.height) {
                                    drag = v.translation.width
                                }
                            }
                            .onEnded { v in
                                guard !rowDragging else {
                                    withAnimation(.snappy) { drag = 0 }
                                    return
                                }
                                if v.translation.width < -80 { close() }
                                withAnimation(.snappy) { drag = 0 }
                            }
                    )
                    .transition(.move(edge: .leading))
                }
            }
            .animation(.snappy(duration: 0.28), value: open)
        }
    }

    func close() {
        rowDragging = false
        withAnimation(.snappy) { open = false }
    }
}

struct DrawerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var close: () -> Void
    @Binding var rowDragging: Bool
    @State private var swipedId: String?
    @State private var deletingProject: Project?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    smartRow(.today, "今天", "sun.max", model.counts.today)
                    smartRow(.tomorrow, "明天", "arrow.right", model.counts.tomorrow)
                    smartRow(.next7, "未來 7 天", "calendar.badge.clock", model.counts.next7Days)
                    smartRow(.inbox, "收件匣", "tray", model.counts.inbox)
                    if model.projects.contains(where: \.isShared) {
                        smartRow(.assigned, "指派給我", "person", model.counts.assignedToMe)
                    }

                    HStack {
                        Text("清單").txt(12, .semibold).foregroundStyle(Palette.textTertiary)
                        Spacer()
                        Menu {
                            Button("新增清單", systemImage: "list.bullet") { close(); model.editingProjectId = "new" }
                            Button("新增資料夾", systemImage: "folder.badge.plus") { newFolder = "" }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.textSecondary)
                                .frame(width: 40, height: 36)
                        }
                        .accessibilityLabel("新增清單或資料夾")
                    }
                    .padding(.leading, 12)
                    .padding(.top, 14)

                    ForEach(model.folders) { f in folderRow(f) }
                    ForEach(lists(in: nil)) { p in listRow(p, indent: false) }

                    if !model.tags.isEmpty {
                        Text("標籤").txt(12, .semibold).foregroundStyle(Palette.textTertiary)
                            .padding(.leading, 12).padding(.top, 14).padding(.bottom, 6)
                        FlowLayout(spacing: 6) {
                            ForEach(model.tags) { t in
                                Button { pick(.tag(t.name)) } label: {
                                    Text("# " + t.label).txt(12, .medium)
                                        .foregroundStyle(isCurrent(.tag(t.name)) ? accent.text : Palette.textNav)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(isCurrent(.tag(t.name)) ? accent.soft : Palette.raised))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
            }
            .background {
                if swipedId != nil {
                    Color.clear.contentShape(Rectangle()).onTapGesture { closeSwipe() }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating, swipedId != nil {
                    closeSwipe()
                }
            }
            HStack(spacing: 8) {
                bottomButton("已完成", .completed)
                bottomButton("垃圾桶", .trash)
            }
            .padding(12)
            .padding(.bottom, 20)
            .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
        }
        .alert("新增資料夾", isPresented: Binding(get: { newFolder != nil }, set: { if !$0 { newFolder = nil } })) {
            TextField("資料夾名稱", text: Binding(get: { newFolder ?? "" }, set: { newFolder = $0 }))
            Button("取消", role: .cancel) {}
            Button("新增") {
                let name = newFolder ?? ""
                Task { await model.perform { try await $0.createFolder(name: name) } }
            }
        }
        .alert("重新命名資料夾", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("資料夾名稱", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("儲存") {
                let id = renaming!.id, name = renameText
                Task { await model.perform { try await $0.updateFolder(id: id, name: name) } }
            }
        }
        .confirmationDialog(
            "刪除「\(deletingProject?.name ?? "")」？清單內的任務會移到垃圾桶。",
            isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除清單", role: .destructive) {
                guard let p = deletingProject else { return }
                Task {
                    await model.perform { try await $0.deleteProject(id: p.id) }
                    if model.scope == .project(p.id) { model.scope = .smart(.today) }
                }
            }
        }
    }

    @State private var newFolder: String?
    @State private var renaming: Folder?
    @State private var renameText = ""

    var header: some View {
        HStack(spacing: 10) {
            let me = model.me
            Text(me?.initial ?? "我")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.background)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(hex: me?.color ?? accent.hex)))
            Text(me?.name ?? "我")
                .txt(16, .semibold)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Spacer()
            Button {
                close()
                model.tab = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.textBody)
                    .frame(width: 40, height: 36)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("設定")
            .accessibilityIdentifier("drawer.settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    func lists(in folder: String?) -> [Project] {
        model.projects.filter { !$0.isInbox && $0.folderId == folder }
    }

    func isCurrent(_ s: TaskScope) -> Bool { model.tab == .tasks && model.scope == s }

    func closeSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { swipedId = nil }
    }

    func pick(_ s: TaskScope) {
        swipedId = nil
        model.scope = s
        model.tab = .tasks
        close()
    }

    func smartRow(_ v: SmartView, _ title: String, _ icon: String, _ count: Int) -> some View {
        row(icon: Image(systemName: icon), title: title, count: count, current: isCurrent(.smart(v)), indent: false) { pick(.smart(v)) }
    }

    func row(icon: some View, title: String, count: Int?, current: Bool, indent: Bool, highlighted: Bool = false, trailing: AnyView? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.font(.system(size: 16)).foregroundStyle(current ? accent.text : Palette.textSecondary).frame(width: 22)
                Text(title).txt(15, current ? .bold : .regular).foregroundStyle(current ? Palette.text : Palette.textBody).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { trailing }
                if let count, count > 0 { Text("\(count)").txt(12).foregroundStyle(current ? accent.text : Palette.textTertiary) }
            }
            .padding(.leading, indent ? 26 : 12)
            .padding(.trailing, 12)
            .frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(current || highlighted ? accent.soft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func folderRow(_ f: Folder) -> some View {
        let open = model.openFolders.contains(f.id)
        let children = lists(in: f.id)
        return VStack(spacing: 2) {
            row(icon: Image(systemName: "folder"), title: f.name, count: children.reduce(0) { $0 + $1.activeCount }, current: false, indent: false,
                trailing: AnyView(Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary).rotationEffect(.degrees(open ? 90 : 0)))) {
                if swipedId != nil { closeSwipe(); return }
                withAnimation(.snappy) {
                    if open { model.openFolders.remove(f.id) } else { model.openFolders.insert(f.id) }
                }
            }
            .contextMenu {
                Button("重新命名", systemImage: "pencil") { renameText = f.name; renaming = f }
                Button("刪除資料夾（保留清單）", systemImage: "trash", role: .destructive) {
                    Task { await model.perform { try await $0.deleteFolder(id: f.id) } }
                }
            }
            .accessibilityValue(open ? "已展開" : "已收合")
            if open {
                ForEach(children) { p in listRow(p, indent: true) }
            }
        }
    }

    func pinToTop(_ p: Project) {
        let siblings = lists(in: p.folderId)
        guard let first = siblings.first, first.id != p.id else { return }
        Task { await model.perform { try await $0.moveProject(id: p.id, beforeProjectId: first.id) } }
    }

    @ViewBuilder
    func listRow(_ p: Project, indent: Bool) -> some View {
        let rowBody = row(icon: ListDot(color: p.color, size: 9), title: p.name, count: p.activeCount, current: isCurrent(.project(p.id)), indent: indent, highlighted: false,
            trailing: p.isShared ? AnyView(Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(Palette.textTertiary).accessibilityLabel("共享清單")) : nil) {
            if swipedId != nil { closeSwipe(); return }
            pick(.project(p.id))
        }
        .accessibilityIdentifier("drawer.list.\(p.name)")

        if p.isViewer {
            rowBody
                .contextMenu {
                    Button("共享協作", systemImage: "person.2") { close(); model.sharingProjectId = p.id }
                }
        } else {
            SwipeableListRow(
                project: p,
                swipedId: $swipedId,
                activeDrag: $rowDragging,
                onPin: { pinToTop(p) },
                onEdit: { close(); model.editingProjectId = p.id },
                onDelete: p.isOwner ? { deletingProject = p } : nil
            ) { isSwiped in
                row(icon: ListDot(color: p.color, size: 9), title: p.name, count: p.activeCount, current: isCurrent(.project(p.id)), indent: indent, highlighted: isSwiped,
                    trailing: p.isShared ? AnyView(Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(Palette.textTertiary).accessibilityLabel("共享清單")) : nil) {
                    if swipedId != nil { closeSwipe(); return }
                    pick(.project(p.id))
                }
                .accessibilityIdentifier("drawer.list.\(p.name)")
                .accessibilityAction(named: "置頂") { pinToTop(p) }
                .accessibilityAction(named: "編輯") { close(); model.editingProjectId = p.id }
                .contextMenu {
                    Button("置頂", systemImage: "arrow.up.to.line") { pinToTop(p) }
                    Button("編輯清單", systemImage: "slider.horizontal.3") { close(); model.editingProjectId = p.id }
                    if p.isOwner {
                        Button("刪除", systemImage: "trash", role: .destructive) { deletingProject = p }
                    }
                }
            }
        }
    }

    func bottomButton(_ title: String, _ v: SmartView) -> some View {
        Button { pick(.smart(v)) } label: {
            Text(title).txt(14, .medium).foregroundStyle(isCurrent(.smart(v)) ? accent.text : Palette.textBody)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
        }
        .buttonStyle(.plain)
    }
}

/// Progressive horizontal swipe actions for drawer list rows:
/// 1 button (刪除) -> 2 buttons (編輯, 刪除) -> 3 buttons (置頂, 編輯, 刪除).
private struct SwipeableListRow<Content: View>: View {
    var project: Project
    @Binding var swipedId: String?
    @Binding var activeDrag: Bool
    var onPin: () -> Void
    var onEdit: () -> Void
    var onDelete: (() -> Void)?
    @ViewBuilder var content: (_ isSwiped: Bool) -> Content

    @State private var baseOffset: CGFloat = 0
    @State private var dragDelta: CGFloat = 0

    private let btnSize: CGFloat = 46
    private let btnSpacing: CGFloat = 8
    private let trailingPad: CGFloat = 6

    private var stop1: CGFloat { btnSize + trailingPad * 2 }
    private var stop2: CGFloat { btnSize * 2 + btnSpacing + trailingPad * 2 }
    private var stop3: CGFloat { btnSize * 3 + btnSpacing * 2 + trailingPad * 2 }

    private var offset: CGFloat {
        let raw = baseOffset + dragDelta
        if raw > 0 { return 0 }
        if raw < -stop3 { return -stop3 + (raw + stop3) * 0.25 }
        return raw
    }

    private var reveal: CGFloat { max(0, -offset) }
    private var showDelete: Bool { onDelete != nil && reveal > 24 }
    private var showEdit: Bool { reveal > 76 }
    private var showPin: Bool { reveal > 126 }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: btnSpacing) {
                actionButton("置頂", systemName: "arrow.up.to.line", bg: Color(hex: "#F7B500"), fg: Color(hex: "#1A1206"), visible: showPin) {
                    close()
                    onPin()
                }
                actionButton("編輯", systemName: "pencil", bg: Color(hex: "#FF8A1E"), fg: .white, visible: showEdit) {
                    close()
                    onEdit()
                }
                if let onDelete {
                    actionButton("刪除", systemName: "trash", bg: Color(hex: "#F2555A"), fg: .white, visible: showDelete) {
                        close()
                        onDelete()
                    }
                }
            }
            .padding(.trailing, trailingPad)

            content(reveal > 2)
                .padding(.trailing, reveal)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .gesture(
            HorizontalPanGesture(
                shouldBegin: { vx in baseOffset < 0 || vx < 0 },
                onChanged: { tx in
                    if !activeDrag {
                        activeDrag = true
                        if swipedId != project.id { swipedId = project.id }
                    }
                    dragDelta = tx
                },
                onEnded: { tx, vx in
                    activeDrag = false
                    let flick = abs(vx) > 800 ? vx * 0.04 : 0
                    let projected = -(baseOffset + tx + flick)
                    let target: CGFloat
                    if projected < 32 {
                        target = 0
                    } else if projected < 86 {
                        target = -stop1
                    } else if projected < 138 {
                        target = -stop2
                    } else {
                        target = -stop3
                    }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        baseOffset = target
                        dragDelta = 0
                    }
                    if target == 0 && swipedId == project.id {
                        swipedId = nil
                    }
                }
            )
        )
        .onChange(of: swipedId) { _, newValue in
            if newValue != project.id && baseOffset != 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    baseOffset = 0
                    dragDelta = 0
                }
            }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            baseOffset = 0
            dragDelta = 0
            if swipedId == project.id { swipedId = nil }
        }
    }

    private func actionButton(_ label: String, systemName: String, bg: Color, fg: Color, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: btnSize, height: btnSize)
                .background(Circle().fill(bg))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(visible ? 1 : 0.3)
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.68), value: visible)
        .allowsHitTesting(visible)
        .accessibilityLabel(label)
        .accessibilityHidden(!visible)
    }
}

/// UIKit pan recognizer that only begins on horizontal drags, so vertical
/// ScrollView scrolling and taps pass through cleanly.
private struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var shouldBegin: (CGFloat) -> Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(shouldBegin: shouldBegin, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let tx = recognizer.translation(in: recognizer.view).x
        let vx = recognizer.velocity(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(tx)
        case .ended, .cancelled, .failed:
            onEnded(tx, vx)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: (CGFloat) -> Bool
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void

        init(shouldBegin: @escaping (CGFloat) -> Bool, onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat, CGFloat) -> Void) {
            self.shouldBegin = shouldBegin
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.15 && shouldBegin(v.x)
        }
    }
}
