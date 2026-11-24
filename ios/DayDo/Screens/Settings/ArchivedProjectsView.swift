import SwiftUI
import DayDoCore

struct ArchivedProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegular
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
                                    if p.isOwner {
                                        Button("取消封存") {
                                            var u = UpdateProjectInput(projectId: p.id)
                                            u.archived = false
                                            let input = u
                                            Task { await model.perform { try await $0.updateProject(input) } }
                                        }
                                        .txt(14, .semibold)
                                        .foregroundStyle(accent.text)
                                        .buttonStyle(.plain)
                                        .hoverEffect(.highlight)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                            }
                        }
                        .card()
                    }
                }
                .frame(maxWidth: isRegular ? 680 : .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, isRegular ? 32 : 140)
                .frame(maxWidth: .infinity)
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
