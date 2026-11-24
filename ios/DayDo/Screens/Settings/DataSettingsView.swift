import SwiftUI
import DayDoCore

struct DataSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegular
    @AppStorage("demoLoaded") private var demoLoaded = false
    @State private var exporting: URL?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        Task {
                            let today = model.today
                            await model.perform { try await DemoData.load(into: $0, today: today) }
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
                    .hoverEffect(.highlight)
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
                        .hoverEffect(.highlight)
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
                        .hoverEffect(.highlight)
                    }
                }
                .card()
                .frame(maxWidth: isRegular ? 680 : .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, isRegular ? 32 : 140)
                .frame(maxWidth: .infinity)
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
            let payload = Export(exportedAt: ISO8601DateFormatter().string(from: model.now), projects: projects,
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
