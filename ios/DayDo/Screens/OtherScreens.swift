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

private enum SettingsRoute: Hashable {
    case appearance
    case archivedProjects
    case data
}

/// Appearance and data settings.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegular
    @State private var path: [SettingsRoute] = []
    @State private var archivedProjects: [Project] = []
    @State private var confirmSignOut = false
    @State private var unsyncedCount = 0
    @State private var editingMeProfile = false
    @State private var linkingEmail = false
    @State private var linkingProvider: AuthProvider?
    @State private var linkError: String?
    @State private var identitiesLoadFailed = false

    private var showAccountSection: Bool {
#if DEBUG
        return (model.syncEnabled && model.isSignedIn) || model.debugAccountPreview
#else
        return model.syncEnabled && model.isSignedIn
#endif
    }

    private var showLoginMethodsSection: Bool {
        model.syncEnabled && model.isSignedIn
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            settingsContent
                .navigationTitle("設定")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(isRegular ? .visible : .hidden, for: .navigationBar)
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .appearance: AppearanceSettingsView()
                    case .archivedProjects: ArchivedProjectsView()
                    case .data: DataSettingsView()
                    }
                }
        }
        .onChange(of: model.tab) { _, tab in
            if tab != .settings && !path.isEmpty {
                path.removeAll()
            }
        }
        .onChange(of: path.isEmpty, initial: true) { _, isEmpty in
            model.hasPushedNavigation = !isEmpty
        }
        .onDisappear {
            model.hasPushedNavigation = false
            if !confirmSignOut {
                model.cancelSignOutConfirmation()
            }
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
            Button("取消", role: .cancel) {
                model.cancelSignOutConfirmation()
            }
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
        .onChange(of: confirmSignOut) { _, isPresented in
            if !isPresented {
                model.cancelSignOutConfirmation()
            }
        }
        .task(id: model.isSignedIn) {
            await fetchIdentities()
        }
        .sheet(isPresented: $editingMeProfile) {
            MeProfileSheet(mode: .edit)
        }
        .sheet(isPresented: $linkingEmail) {
            EmailCodeSheet(mode: .link) { email, code in
                try await model.linkIdentity(with: .email(email: email, code: code))
                linkError = nil
            }
        }
    }

    private var settingsContent: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !isRegular {
                        Text("設定").txt(30, .bold).foregroundStyle(Palette.text)
                            .padding(.horizontal, 4)
                    }

                    if showAccountSection {
                        VStack(spacing: 0) {
                            Button {
                                editingMeProfile = true
                            } label: {
                                HStack(spacing: 12) {
                                    let me = model.me
                                    AvatarView(member: me, size: 34, fallbackColor: accent.hex)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(me?.name ?? "").txt(15, .semibold).foregroundStyle(Palette.text)
                                        Text(model.isSyncing ? "正在同步…" : "已登入").txt(12).foregroundStyle(Palette.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 58)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.press(scale: 0.985, opacity: 0.92, highlight: Palette.pressHighlight))
                            .hoverEffect(.highlight)
                            .accessibilityIdentifier("settings.accountRow")

                            divider

                            Button {
                                Task {
                                    unsyncedCount = await model.prepareSignOutConfirmation()
                                    if model.isSignedIn {
                                        confirmSignOut = true
                                    } else {
                                        model.cancelSignOutConfirmation()
                                    }
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
                            .buttonStyle(.press(scale: 0.985, opacity: 0.92, highlight: Palette.pressHighlight))
                            .hoverEffect(.highlight)
                            .accessibilityIdentifier("settings.signOut")
                        }
                        .card()
                    }

                    if showLoginMethodsSection {
                        loginMethodsSection
                    }

                    VStack(spacing: 0) {
                        NavigationLink(value: SettingsRoute.appearance) {
                            row(icon: "paintpalette", title: "外觀")
                        }
                        .buttonStyle(.press(scale: 0.985, opacity: 0.92, highlight: Palette.pressHighlight))
                        .hoverEffect(.highlight)

                        if !archivedProjects.isEmpty {
                            divider
                            NavigationLink(value: SettingsRoute.archivedProjects) {
                                row(icon: "archivebox", title: "已封存的清單", value: "\(archivedProjects.count)")
                            }
                            .buttonStyle(.press(scale: 0.985, opacity: 0.92, highlight: Palette.pressHighlight))
                            .hoverEffect(.highlight)
                        }
                    }
                    .card()

                    VStack(spacing: 0) {
                        NavigationLink(value: SettingsRoute.data) {
                            row(icon: "externaldrive", title: "資料")
                        }
                        .buttonStyle(.press(scale: 0.985, opacity: 0.92, highlight: Palette.pressHighlight))
                        .hoverEffect(.highlight)
                    }
                    .card()

                    VStack(spacing: 0) {
                        row(icon: "info.circle", title: "關於", value: versionText, chevron: false)
                    }
                    .card()
                }
                .frame(maxWidth: isRegular ? 680 : .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isRegular ? 32 : 140)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.leading, 50)
    }

    private var loginMethodsSection: some View {
        let linked = model.linkedIdentities
        let linkedProviders = Set(linked.map(\.provider))
        let unlinkedProviders: [AuthProvider] = [.google, .email, .apple].filter { provider in
            if provider == .apple && Platform.isMac { return false }
            return !linkedProviders.contains(provider)
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text("登入方式")
                .txt(12, .semibold)
                .foregroundStyle(Palette.textTertiary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                if !model.identitiesLoaded && model.isLoadingIdentities {
                    HStack(spacing: 12) {
                        ProgressView().tint(Palette.textSecondary)
                        Text("正在載入登入方式…")
                            .txt(14)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                } else if !model.identitiesLoaded && identitiesLoadFailed {
                    HStack(spacing: 12) {
                        Text("無法載入登入方式")
                            .txt(14)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("重試") {
                            Task { await fetchIdentities() }
                        }
                        .txt(14, .semibold)
                        .foregroundStyle(accent.text)
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                } else {
                    ForEach(Array(linked.enumerated()), id: \.element.id) { index, identity in
                        if index > 0 { divider }
                        linkedIdentityRow(identity)
                    }

                    ForEach(Array(unlinkedProviders.enumerated()), id: \.element) { index, provider in
                        if !linked.isEmpty || index > 0 { divider }
                        linkProviderButton(provider)
                    }
                }
            }
            .card()

            if let linkError {
                Text(linkError)
                    .txt(13)
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(12, color: Palette.raised)
                    .accessibilityIdentifier("settings.identity.error")
            }
        }
    }

    private func linkedIdentityRow(_ identity: LinkedIdentity) -> some View {
        HStack(spacing: 12) {
            providerIcon(identity.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(providerTitle(identity.provider))
                    .txt(15)
                    .foregroundStyle(Palette.text)
                if let email = identity.email, !email.isEmpty {
                    Text(email)
                        .txt(12)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text("已連結")
                .txt(13)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.identity.linked.\(identity.provider.rawValue)")
    }

    private func linkProviderButton(_ provider: AuthProvider) -> some View {
        Button {
            handleLinkProviderTap(provider)
        } label: {
            HStack(spacing: 12) {
                providerIcon(provider)
                Text(linkButtonTitle(provider))
                    .txt(15)
                    .foregroundStyle(Palette.text)
                Spacer()
                if linkingProvider == provider {
                    ProgressView().tint(Palette.textSecondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press(scale: 0.985, opacity: 0.92, highlight: Palette.pressHighlight))
        .hoverEffect(.highlight)
        .disabled(linkingProvider != nil)
        .accessibilityIdentifier("settings.identity.link.\(provider.rawValue)")
    }

    @ViewBuilder
    private func providerIcon(_ provider: AuthProvider) -> some View {
        switch provider {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 24)
        case .google:
            Text("G")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Palette.text)
                .frame(width: 24)
        case .email:
            Image(systemName: "envelope")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(accent.text)
                .frame(width: 24)
        }
    }

    private func providerTitle(_ provider: AuthProvider) -> String {
        switch provider {
        case .apple: "Apple"
        case .google: "Google"
        case .email: "Email"
        }
    }

    private func linkButtonTitle(_ provider: AuthProvider) -> String {
        switch provider {
        case .apple: "連結 Apple"
        case .google: "連結 Google"
        case .email: "連結 Email"
        }
    }

    private func fetchIdentities() async {
        guard showLoginMethodsSection else { return }
        identitiesLoadFailed = false
        do {
            _ = try await model.loadLinkedIdentities()
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                identitiesLoadFailed = true
            }
        }
    }

    private func handleLinkProviderTap(_ provider: AuthProvider) {
        linkError = nil
        switch provider {
        case .email:
            linkingEmail = true
        case .google:
            linkingProvider = .google
            Task {
                defer { linkingProvider = nil }
                do {
                    guard let payload = try await AuthPresentationHelper.signInWithGoogle() else { return }
                    _ = try await model.linkIdentity(with: .google(idToken: payload.idToken))
                } catch {
                    linkError = error.localizedDescription
                }
            }
        case .apple:
            guard !Platform.isMac else { return }
            linkingProvider = .apple
            Task {
                defer { linkingProvider = nil }
                do {
                    guard let payload = try await AuthPresentationHelper.signInWithApple() else { return }
                    _ = try await model.linkIdentity(with: .apple(identityToken: payload.identityToken, nonce: payload.nonce))
                } catch {
                    linkError = error.localizedDescription
                }
            }
        }
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
    @Environment(\.isRegularWindow) private var isRegular

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
                                .buttonStyle(.press)
                                .hoverEffect(.highlight)
                                .accessibilityAddTraits(model.accentHex == hex ? .isSelected : [])
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }

                    section("顯示") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("外觀").txt(15).foregroundStyle(Palette.text)
                            HStack(spacing: 8) {
                                OptionChip(label: "深色", on: model.appearance == .dark) { model.appearance = .dark }
                                OptionChip(label: "淺色", on: model.appearance == .light) { model.appearance = .light }
                                OptionChip(label: "跟隨系統", on: model.appearance == .system) { model.appearance = .system }
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.leading, 14)

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
                .frame(maxWidth: isRegular ? 680 : .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, isRegular ? 32 : 140)
                .frame(maxWidth: .infinity)
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

private struct DataSettingsView: View {
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
