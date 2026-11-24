import SwiftUI
import DayDoCore

/// 搜尋: titles, descriptions, tags and subtasks.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isRegularWindow) private var isRegular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool = true
    @State private var text = ""
    @State private var activeOnly = false
    @State private var query = ResidentQuery<SearchKey, [TodoTask]>(
        initialValue: [],
        debounce: { loaded, next in
            guard !next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .zero }
            return loaded?.text == next.text ? .zero : .milliseconds(180)
        }
    )
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @FocusState private var focused: Bool

    private var results: [TodoTask] { query.value }

    private var activeSearchKey: SearchKey? {
        isActive ? SearchKey(text: text, activeOnly: activeOnly, revision: model.revision) : nil
    }

    var body: some View {
        ZStack {
            if isRegular {
                Palette.background.ignoresSafeArea()
            }
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                        TextField("搜尋任務、描述、標籤、子任務", text: $text)
                            .txt(16).foregroundStyle(Palette.text)
                            .focused($focused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .accessibilityHidden(!isActive)
                        if !text.isEmpty {
                            Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary) }
                                .buttonStyle(.plain).hoverEffect(.highlight).accessibilityLabel("清除搜尋")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                }
                .padding(.horizontal, 16)
                .padding(.top, isRegular ? 12 : 6)

                HStack {
                    OptionChip(label: "全部", on: !activeOnly) { activeOnly = false }
                    OptionChip(label: "只看未完成", on: activeOnly) { activeOnly = true }
                    Spacer()
                }
                .padding(.horizontal, 16)

                ScrollView {
                    let firstId = results.first?.id
                    LazyVStack(spacing: 0) {
                        ForEach(results) { t in
                            TaskRow(task: t, separator: t.id != firstId, sectionKind: .other("search"))
                                .transition(Motion.rowTransition(reduceMotion))
                        }
                    }
                    .card()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(results.isEmpty ? 0 : 1)
                    .enclosingScrollsToTop(isActive)
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
                                        .buttonStyle(.press)
                                        .hoverEffect(.highlight)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .scrollPosition($scrollPosition)
                .padding(.horizontal, 16)
                .contentMargins(.bottom, isRegular ? 32 : 140, for: .scrollContent)
                .scrollDismissesKeyboard(.immediately)
            }
            .frame(maxWidth: isRegular ? 760 : .infinity)
        }
        .navigationTitle("搜尋")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: activeSearchKey) {
            let key = activeSearchKey
            let isEmptyQuery = key?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let outcome = await query.run(activeKey: key) { key in
                if key.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return []
                }
                return try await model.api.searchTasks(text: key.text, activeOnly: key.activeOnly)
            } apply: { _, commit in
                if !query.value.isEmpty || !isEmptyQuery {
                    withAnimation(Motion.layout(reduceMotion)) { commit() }
                } else {
                    commit()
                }
            }
            if case .failed(let error) = outcome {
                model.errorMessage = error.localizedDescription
            }
        }
        .onAppear { if isActive && text.isEmpty { focused = true } }
        .onChange(of: isActive) { _, active in
            if active {
                if !text.isEmpty { text = "" }
                if activeOnly { activeOnly = false }
                if !query.value.isEmpty || query.loadedKey.map({ !$0.text.isEmpty || $0.activeOnly }) == true {
                    query.reset()
                }
                if scrollPosition.isPositionedByUser || scrollPosition.edge != .top {
                    scrollPosition.scrollTo(edge: .top)
                }
                if !focused { focused = true }
            } else if focused {
                focused = false
            }
        }
        .onChange(of: model.searchFocusTrigger) { _, _ in focused = true }
    }
}

struct SearchKey: Hashable { var text: String; var activeOnly: Bool; var revision: Int }
