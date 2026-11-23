import AuthenticationServices
import SwiftUI
import DayDoCore

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var logoNamespace: Namespace.ID? = nil
    var logoRevealed: Bool = true
    var contentRevealed: Bool = true

    private struct PendingAccountSwitch {
        let auth: AuthLoginResponse
        let credential: SyncAuthCredential
        let displayName: String?
        let avatarUrl: String?
        let unsyncedCount: Int
    }

    @State private var currentRawNonce: String?
    @State private var errorText: String?
    @State private var showingEmailSignIn = false
    @State private var pendingSwitch: PendingAccountSwitch?
    @State private var pendingSwitchAfterSheetDismiss: PendingAccountSwitch?
    @State private var confirmSwitchAccount = false

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Group {
                        if logoRevealed {
                            Image("LaunchLogo")
                                .resizable()
                                .frame(width: 120, height: 120)
                                .matchedGeometryIfPresent(id: "launchLogo", in: logoNamespace)
                                .transition(.identity)
                        } else {
                            Color.clear
                                .frame(width: 120, height: 120)
                        }
                    }

                    VStack(spacing: 16) {
                        Text("DayDo")
                            .txt(34, .bold)
                            .foregroundStyle(Palette.text)

                        Text("待辦與日曆，跨裝置即時同步")
                            .txt(15)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .opacity(contentRevealed ? 1 : 0)
                }

                Spacer()

                VStack(spacing: 12) {
                    if let errorText {
                        Text(errorText)
                            .txt(13)
                            .foregroundStyle(Palette.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .card(12, color: Palette.raised)
                    }

                    if !Platform.isMac {
                        SignInWithAppleButton(.signIn) { request in
                            let rawNonce = SignInNonce.random()
                            currentRawNonce = rawNonce
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = SignInNonce.sha256Hex(rawNonce)
                        } onCompletion: { result in
                            handleAppleResult(result)
                        }
                        .signInWithAppleButtonStyle(colorScheme == .light ? .black : .white)
                        .id(colorScheme)
                        .frame(height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("signIn.apple")
                        .disabled(model.isSigningIn)
                    }

                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack(spacing: 10) {
                            Text("G")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Palette.text)
                            Text("使用 Google 登入")
                                .txt(17, .semibold)
                                .foregroundStyle(Palette.text)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Palette.raised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Palette.separatorSoft, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier("signIn.google")
                    .disabled(model.isSigningIn)

                    Button {
                        errorText = nil
                        showingEmailSignIn = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "envelope")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Palette.text)
                            Text("使用 Email 登入")
                                .txt(17, .semibold)
                                .foregroundStyle(Palette.text)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Palette.raised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Palette.separatorSoft, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier("signIn.email")
                    .disabled(model.isSigningIn)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 44)
                .opacity(contentRevealed ? 1 : 0)
            }
            .frame(maxWidth: 420)

            if model.isSigningIn {
                Palette.scrim.ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().tint(Palette.text)
                    Text("正在登入並同步資料…")
                        .txt(14, .medium)
                        .foregroundStyle(Palette.textBody)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .card(18, color: Palette.card)
            }
        }
        .sheet(isPresented: $showingEmailSignIn, onDismiss: {
            if let deferred = pendingSwitchAfterSheetDismiss {
                pendingSwitchAfterSheetDismiss = nil
                pendingSwitch = deferred
                confirmSwitchAccount = true
            }
        }) {
            EmailCodeSheet(mode: .signIn) { email, code in
                try await performEmailSignIn(email: email, code: code)
            }
        }
        .alert("切換帳號？", isPresented: $confirmSwitchAccount) {
            Button("取消", role: .cancel) {
                pendingSwitch = nil
            }
            Button("清除並登入", role: .destructive) {
                guard let pending = pendingSwitch else { return }
                pendingSwitch = nil
                Task {
                    await confirmAccountSwitch(pending)
                }
            }
        } message: {
            let unsynced = pendingSwitch?.unsyncedCount ?? 0
            if unsynced > 0 {
                Text("這支手機上還有另一個帳號的資料。要清除這些資料並改用這個帳號登入嗎？\n其中 \(unsynced) 筆修改還沒同步，會一併刪除")
            } else {
                Text("這支手機上還有另一個帳號的資料。要清除這些資料並改用這個帳號登入嗎？")
            }
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  !identityToken.isEmpty,
                  let rawNonce = currentRawNonce else {
                errorText = "無法讀取 Apple 登入憑證，請再試一次。"
                return
            }
            currentRawNonce = nil
            let fullName = credential.fullName.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let suggestedName = (fullName?.isEmpty == false) ? fullName : nil
            Task {
                await performSignIn(.apple(identityToken: identityToken, nonce: rawNonce), displayName: suggestedName)
            }
        case .failure(let error):
            currentRawNonce = nil
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            errorText = AuthErrorMessage.text(for: error)
        }
    }

    private func signInWithGoogle() {
        errorText = nil
        Task {
            do {
                guard let payload = try await AuthPresentationHelper.signInWithGoogle() else { return }
                await performSignIn(.google(idToken: payload.idToken), displayName: payload.displayName, avatarUrl: payload.avatarUrl)
            } catch {
                errorText = AuthErrorMessage.text(for: error)
            }
        }
    }

    private func performEmailSignIn(email: String, code: String) async throws {
        let credential = SyncAuthCredential.email(email: email, code: code)
        errorText = nil
        do {
            try await model.signIn(with: credential, displayName: nil, avatarUrl: nil)
        } catch let AuthError.differentAccount(auth) {
            let unsynced = await model.unsyncedChangeCount()
            pendingSwitchAfterSheetDismiss = PendingAccountSwitch(
                auth: auth,
                credential: credential,
                displayName: nil,
                avatarUrl: nil,
                unsyncedCount: unsynced
            )
            return
        }
    }

    private func performSignIn(_ credential: SyncAuthCredential, displayName: String?, avatarUrl: String? = nil) async {
        errorText = nil
        do {
            try await model.signIn(with: credential, displayName: displayName, avatarUrl: avatarUrl)
        } catch let AuthError.differentAccount(auth) {
            let unsynced = await model.unsyncedChangeCount()
            pendingSwitch = PendingAccountSwitch(
                auth: auth,
                credential: credential,
                displayName: displayName,
                avatarUrl: avatarUrl,
                unsyncedCount: unsynced
            )
            confirmSwitchAccount = true
        } catch {
            errorText = AuthErrorMessage.text(for: error)
        }
    }

    private func confirmAccountSwitch(_ pending: PendingAccountSwitch) async {
        errorText = nil
        do {
            try await model.replaceAccountAndSignIn(
                with: pending.auth,
                credential: pending.credential,
                displayName: pending.displayName,
                avatarUrl: pending.avatarUrl
            )
        } catch {
            errorText = AuthErrorMessage.text(for: error)
        }
    }
}
