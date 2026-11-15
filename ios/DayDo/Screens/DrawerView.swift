import SwiftUI
import DayDoCore

/// 1a · Left list drawer: smart lists, folders (expandable), loose lists,
/// tags, and 已完成／垃圾桶 at the bottom.
struct DrawerOverlay: View {
    @Environment(AppModel.self) private var model
    @Binding var open: Bool
    @State private var drag: CGFloat = 0

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
                DrawerView(close: close)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Palette.card.ignoresSafeArea())
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28, style: .continuous))
                    .ignoresSafeArea(edges: .bottom)
                    .offset(x: min(0, drag))
                    .gesture(DragGesture().onChanged { drag = $0.translation.width }.onEnded { v in
                        if v.translation.width < -80 { close() }
                        withAnimation(.snappy) { drag = 0 }
                    })
                    .transition(.move(edge: .leading))
                }
            }
            .animation(.snappy(duration: 0.28), value: open)
        }
    }

    func close() { withAnimation(.snappy) { open = false } }
}

struct DrawerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var close: () -> Void

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
    }

    @State private var newFolder: String?
    @State private var renaming: Folder?
    @State private var renameText = ""

    var header: some View {
        HStack(spacing: 10) {
            // No account yet: no avatar or sync status until phase 2 adds sign-in.
            Spacer()
            Button { close(); model.showSettings = true } label: {
                Image(systemName: "gearshape").frame(width: 40, height: 40)
            }
            .accessibilityLabel("設定")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textBody)
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    func lists(in folder: String?) -> [Project] {
        model.projects.filter { !$0.isInbox && $0.folderId == folder }
    }

    func isCurrent(_ s: TaskScope) -> Bool { model.tab == .tasks && model.scope == s }

    func pick(_ s: TaskScope) {
        model.scope = s
        model.tab = .tasks
        close()
    }

    func smartRow(_ v: SmartView, _ title: String, _ icon: String, _ count: Int) -> some View {
        row(icon: Image(systemName: icon), title: title, count: count, current: isCurrent(.smart(v)), indent: false) { pick(.smart(v)) }
    }

    func row(icon: some View, title: String, count: Int?, current: Bool, indent: Bool, trailing: AnyView? = nil, action: @escaping () -> Void) -> some View {
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
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(current ? accent.soft : .clear))
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

    func listRow(_ p: Project, indent: Bool) -> some View {
        row(icon: ListDot(color: p.color, size: 9), title: p.name, count: p.activeCount, current: isCurrent(.project(p.id)), indent: indent,
            trailing: p.isShared ? AnyView(Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(Palette.textTertiary).accessibilityLabel("共享清單")) : nil) {
            pick(.project(p.id))
        }
        .accessibilityIdentifier("drawer.list.\(p.name)")
        .contextMenu {
            Button("編輯清單", systemImage: "slider.horizontal.3") { close(); model.editingProjectId = p.id }
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
