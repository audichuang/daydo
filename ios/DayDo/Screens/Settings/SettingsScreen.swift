import SwiftUI
import DayDoCore

enum SettingsRoute: Hashable {
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
                .environment(model)
        }
        .sheet(isPresented: $linkingEmail) {
            EmailCodeSheet(mode: .link) { email, code in
                do {
                    try await model.linkIdentity(with: .email(email: email, code: code))
                    linkError = nil
                } catch let AuthError.linkUnconfirmed(refreshed) {
                    linkError = AuthErrorMessage.text(for: AuthError.linkUnconfirmed(refreshed))
                }
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
                if !model.identitiesLoaded && identitiesLoadFailed {
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
                        .accessibilityIdentifier("settings.identity.retry")
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                } else if !model.identitiesLoaded {
                    HStack(spacing: 12) {
                        ProgressView().tint(Palette.textSecondary)
                        Text("正在載入登入方式…")
                            .txt(14)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
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

                    if identitiesLoadFailed {
                        if !linked.isEmpty || !unlinkedProviders.isEmpty { divider }
                        HStack(spacing: 12) {
                            Text("更新失敗")
                                .txt(13)
                                .foregroundStyle(Palette.textSecondary)
                            Spacer()
                            Button("重試") {
                                Task { await fetchIdentities() }
                            }
                            .txt(13, .semibold)
                            .foregroundStyle(accent.text)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.identity.retry")
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.identity.refreshFailed")
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
                defer {
                    AuthPresentationHelper.signOutGoogleSession()
                    linkingProvider = nil
                }
                do {
                    guard let payload = try await AuthPresentationHelper.signInWithGoogle() else { return }
                    _ = try await model.linkIdentity(with: .google(idToken: payload.idToken))
                } catch {
                    linkError = AuthErrorMessage.text(for: error)
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
                    linkError = AuthErrorMessage.text(for: error)
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
        .frame(minHeight: Platform.isMac ? 40 : 52)
        .contentShape(Rectangle())
    }
}
