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
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    @AppStorage("demoLoaded") private var demoLoaded = false
    @State private var exporting: URL?
    @State private var archivedProjects: [Project] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("主題色") {
                    HStack(spacing: 14) {
                        ForEach(Palette.accentOptions, id: \.self) { hex in
                            Button { model.accentHex = hex } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(model.accentHex == hex ? Palette.text : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("顯示") {
                    Picker("列表密度", selection: $model.compact) {
                        Text("標準").tag(false)
                        Text("緊湊").tag(true)
                    }
                    Picker("文字大小", selection: $model.textScale) {
                        Text("100%").tag(1.0)
                        Text("115%").tag(1.15)
                        Text("130%").tag(1.3)
                    }
                }
                Section {
                    Button("載入範例資料") {
                        Task {
                            await model.perform { try await DemoData.load(into: $0) }
                            demoLoaded = true
                        }
                    }
                    .disabled(demoLoaded)
                    if let exporting {
                        ShareLink("分享匯出的 JSON", item: exporting)
                    } else {
                        Button("匯出所有任務（JSON）") { Task { exporting = await export() } }
                    }
                } header: {
                    Text("資料")
                } footer: {
                    Text("資料目前只存在這台裝置。匯出格式與之後的同步 API 相同（snake_case JSON）。")
                }
                if !archivedProjects.isEmpty {
                    Section("已封存的清單") {
                        ForEach(archivedProjects) { p in
                            HStack(spacing: 10) {
                                ListDot(color: p.color, size: 9)
                                Text(p.name).foregroundStyle(Palette.text)
                                Spacer()
                                Button("取消封存") {
                                    var u = UpdateProjectInput(projectId: p.id)
                                    u.archived = false
                                    let input = u
                                    Task { await model.perform { try await $0.updateProject(input) } }
                                }
                                .foregroundStyle(accent.text)
                            }
                        }
                    }
                }
                Section("關於") {
                    LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.card)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationBackground(Palette.card)
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
