import SwiftUI
import DayDoCore

/// 搜尋: titles, descriptions, tags and subtasks.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var activeOnly = false
    @State private var results: [TodoTask] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                    TextField("搜尋任務、描述、標籤、子任務", text: $text)
                        .txt(16).foregroundStyle(Palette.text)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if !text.isEmpty {
                        Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary) }
                            .buttonStyle(.plain).accessibilityLabel("清除搜尋")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            HStack {
                OptionChip(label: "全部", on: !activeOnly) { activeOnly = false }
                OptionChip(label: "只看未完成", on: activeOnly) { activeOnly = true }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, t in
                        TaskRow(task: t, separator: i > 0, sectionId: "search")
                    }
                }
                .card()
                .opacity(results.isEmpty ? 0 : 1)
                if results.isEmpty {
                    Text(text.isEmpty ? (model.tags.isEmpty ? "輸入關鍵字開始搜尋" : "") : "找不到「\(text)」")
                        .txt(14).foregroundStyle(Palette.textSecondary).padding(.top, 30)
                    if text.isEmpty && !model.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("標籤").txt(12, .semibold).foregroundStyle(Palette.textTertiary)
                            FlowLayout(spacing: 6) {
                                ForEach(model.tags) { tag in
                                    Button { model.scope = .tag(tag.name); model.tab = .tasks } label: {
                                        TagChip(name: tag.name, label: tag.label, color: tag.color)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .contentMargins(.bottom, 140, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
        }
        .task(id: SearchKey(text: text, activeOnly: activeOnly, revision: model.revision)) {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let found = try await model.api.searchTasks(text: text, activeOnly: activeOnly)
                guard !Task.isCancelled else { return }
                results = found
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { model.errorMessage = error.localizedDescription }
            }
        }
        .onAppear { if text.isEmpty { focused = true } }
    }
}

struct SearchKey: Hashable { var text: String; var activeOnly: Bool; var revision: Int }

/// Appearance and data settings.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @State private var archivedProjects: [Project] = []
    @State private var confirmSignOut = false
    @State private var unsyncedCount = 0

    private var showAccountSection: Bool {
#if DEBUG
        return (model.syncEnabled && model.isSignedIn) || model.debugAccountPreview
#else
        return model.syncEnabled && model.isSignedIn
#endif
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("設定").txt(30, .bold).foregroundStyle(Palette.text)
                            .padding(.horizontal, 4)

                        if showAccountSection {
                            VStack(spacing: 0) {
                                HStack(spacing: 12) {
                                    let me = model.me
                                    Text(me?.initial ?? "我")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Palette.background)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(Color(hex: me?.color ?? accent.hex)))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(me?.name ?? "我").txt(15, .semibold).foregroundStyle(Palette.text)
                                        Text(model.isSyncing ? "正在同步…" : "已登入").txt(12).foregroundStyle(Palette.textSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 58)
                                .accessibilityIdentifier("settings.accountRow")

                                divider

                                Button {
                                    model.showingJoinInvite = true
                                } label: {
                                    row(icon: "person.badge.plus", title: "加入共享清單")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("settings.joinInvite")

                                divider

                                Button {
                                    Task {
                                        unsyncedCount = await model.unsyncedChangeCount()
                                        confirmSignOut = true
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "rectangle.portrait.and.arrow.right")
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(Palette.danger)
                                            .frame(width: 24)
                                        Text("登出").txt(15, .medium).foregroundStyle(Palette.danger)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 52)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("settings.signOut")
                            }
                            .card()
                        }

                        VStack(spacing: 0) {
                            NavigationLink {
                                AppearanceSettingsView()
                            } label: {
                                row(icon: "paintpalette", title: "外觀")
                            }
                            .buttonStyle(.plain)

                            if !archivedProjects.isEmpty {
                                divider
                                NavigationLink {
                                    ArchivedProjectsView()
                                } label: {
                                    row(icon: "archivebox", title: "已封存的清單", value: "\(archivedProjects.count)")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .card()

                        VStack(spacing: 0) {
                            NavigationLink {
                                DataSettingsView()
                            } label: {
                                row(icon: "externaldrive", title: "資料")
                            }
                            .buttonStyle(.plain)
                        }
                        .card()

                        VStack(spacing: 0) {
                            row(icon: "info.circle", title: "關於", value: versionText, chevron: false)
                        }
                        .card()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 140)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("設定")
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: model.revision) {
            do {
                let all = try await model.api.listProjects(includeArchived: true)
                guard !Task.isCancelled else { return }
                archivedProjects = all.filter(\.archived)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { model.errorMessage = error.localizedDescription }
            }
        }
        .alert("確定要登出？", isPresented: $confirmSignOut) {
            Button("取消", role: .cancel) {}
            Button("登出", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            if unsyncedCount > 0 {
                Text("登出會清除這台裝置上的所有本機資料。目前還有 \(unsyncedCount) 筆尚未同步的變更，登出後將會遺失。")
            } else {
                Text("登出會清除這台裝置上的所有本機資料，下次登入後可從雲端同步回來。")
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.leading, 50)
    }

    private func row(icon: String, title: String, value: String? = nil, chevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(accent.text)
                .frame(width: 24)
            Text(title).txt(15).foregroundStyle(Palette.text)
            Spacer()
            if let value {
                Text(value).txt(14).foregroundStyle(Palette.textSecondary)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

private struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("主題色") {
                        HStack(spacing: 14) {
                            ForEach(Palette.accentOptions, id: \.self) { hex in
                                Button { model.accentHex = hex } label: {
                                    Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(model.accentHex == hex ? Palette.text : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(model.accentHex == hex ? .isSelected : [])
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }

                    section("顯示") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("列表密度").txt(15).foregroundStyle(Palette.text)
                            HStack(spacing: 8) {
                                OptionChip(label: "標準", on: !model.compact) { model.compact = false }
                                OptionChip(label: "緊湊", on: model.compact) { model.compact = true }
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.leading, 14)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("文字大小").txt(15).foregroundStyle(Palette.text)
                            HStack(spacing: 8) {
                                OptionChip(label: "100%", on: model.textScale == 1.0) { model.textScale = 1.0 }
                                OptionChip(label: "115%", on: model.textScale == 1.15) { model.textScale = 1.15 }
                                OptionChip(label: "130%", on: model.textScale == 1.3) { model.textScale = 1.3 }
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("外觀")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).txt(12, .semibold).foregroundStyle(Palette.textTertiary).padding(.leading, 4)
            VStack(spacing: 0) { content() }.card()
        }
    }
}

private struct ArchivedProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @State private var archivedProjects: [Project] = []

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if archivedProjects.isEmpty {
                        Text("沒有已封存的清單")
                            .txt(14)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .card()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(archivedProjects.enumerated()), id: \.element.id) { i, p in
                                if i > 0 {
                                    Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.leading, 14)
                                }
                                HStack(spacing: 10) {
                                    ListDot(color: p.color, size: 9)
                                    Text(p.name).txt(15).foregroundStyle(Palette.text)
                                    Spacer()
                                    Button("取消封存") {
                                        var u = UpdateProjectInput(projectId: p.id)
                                        u.archived = false
                                        let input = u
                                        Task { await model.perform { try await $0.updateProject(input) } }
                                    }
                                    .txt(14, .semibold)
                                    .foregroundStyle(accent.text)
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                            }
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("已封存的清單")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.revision) {
            do {
                let all = try await model.api.listProjects(includeArchived: true)
                guard !Task.isCancelled else { return }
                archivedProjects = all.filter(\.archived)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { model.errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct DataSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @AppStorage("demoLoaded") private var demoLoaded = false
    @State private var exporting: URL?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        Task {
                            await model.perform { try await DemoData.load(into: $0) }
                            demoLoaded = true
                        }
                    } label: {
                        HStack {
                            Text("載入範例資料").txt(15).foregroundStyle(demoLoaded ? Palette.textFaint : Palette.text)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(demoLoaded)

                    Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.leading, 14)

                    if let exporting {
                        ShareLink(item: exporting) {
                            HStack {
                                Text("分享匯出的 JSON").txt(15).foregroundStyle(accent.text)
                                Spacer()
                                Image(systemName: "square.and.arrow.up").foregroundStyle(accent.text)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            Task { exporting = await export() }
                        } label: {
                            HStack {
                                Text("匯出所有任務（JSON）").txt(15).foregroundStyle(Palette.text)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .card()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("資料")
        .navigationBarTitleDisplayMode(.inline)
    }

    struct Export: Encodable {
        var exportedAt: String
        var projects: [Project]
        var folders: [Folder]
        var tags: [Tag]
        var tasks: [TodoTask]
    }

    func export() async -> URL? {
        do {
            let api = model.api
            let projects = try await api.listProjects(includeArchived: true)
            var allTasks = try await api.listTasks(TaskQuery(includeCompleted: true))
            for p in projects where p.archived {
                allTasks += try await api.listTasks(TaskQuery(projectId: p.id, includeCompleted: true))
            }
            let payload = Export(exportedAt: ISO8601DateFormatter().string(from: Date()), projects: projects,
                                 folders: try await api.listFolders(), tags: try await api.listTags(), tasks: allTasks)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("DayDo-export.json")
            try DayDoJSON.encoder.encode(payload).write(to: url)
            return url
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }
}
