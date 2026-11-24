import AuthenticationServices
import SwiftUI
import UIKit
import DayDoCore

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private enum MacField: Hashable {
        case email
        case code
    }

    @State private var currentRawNonce: String?
    @State private var errorText: String?
    @State private var showingEmailSignIn = false
    @State private var emailFlow = EmailCodeFlow()
    @FocusState private var macFocusedField: MacField?
    @State private var pendingSwitch: PendingAccountSwitch?
    @State private var pendingSwitchAfterSheetDismiss: PendingAccountSwitch?
    @State private var confirmSwitchAccount = false

    private var macBusy: Bool {
        model.isSigningIn || emailFlow.busy
    }

    private var canSendMacEmailCode: Bool {
        emailFlow.canSendCode && !model.isSigningIn
    }

    private var canSubmitMacEmailCode: Bool {
        emailFlow.canSubmitCode && !model.isSigningIn
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            if Platform.isMac {
                macSignInContent
            } else {
                mobileSignInContent
            }

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
        .background {
            if Platform.isMac {
                MacWindowMinSizeBridge(minimumSize: CGSize(width: 760, height: 520))
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
                try await performEmailSignIn(email: email, code: code, deferSwitchUntilSheetDismiss: true)
            }
        }
        .alert("切換帳號？", isPresented: $confirmSwitchAccount) {
            Button("取消", role: .cancel) {
                let canceledCredential = pendingSwitch?.credential
                pendingSwitch = nil
                if Platform.isMac,
                   case .email = canceledCredential,
                   emailFlow.step == .enterCode {
                    emailFlow.backToEmail()
                    focusMacField(.email)
                }
            }
            Button("清除並登入", role: .destructive) {
                guard let pending = pendingSwitch else { return }
                pendingSwitch = nil
                Task {
                    await confirmAccountSwitch(pending)
                }
            }
        } message: {
            let device = Platform.isMac ? "這台 Mac" : "這支手機"
            let unsynced = pendingSwitch?.unsyncedCount ?? 0
            if unsynced > 0 {
                Text("\(device)上還有另一個帳號的資料。要清除這些資料並改用這個帳號登入嗎？\n其中 \(unsynced) 筆修改還沒同步，會一併刪除")
            } else {
                Text("\(device)上還有另一個帳號的資料。要清除這些資料並改用這個帳號登入嗎？")
            }
        }
    }

    private var mobileSignInContent: some View {
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
    }

    private var macSignInContent: some View {
        HStack(spacing: 0) {
            macBrandPanel
                .frame(width: 300)

            Rectangle()
                .fill(Palette.separator)
                .frame(width: 1)
                .opacity(contentRevealed ? 1 : 0)

            macFormPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(contentRevealed ? 1 : 0)
        }
        .frame(width: 720, height: 440)
        .background(
            Palette.card
                .opacity(contentRevealed ? 1 : 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
                .opacity(contentRevealed ? 1 : 0)
        )
        .shadow(color: Palette.navShadow.opacity(contentRevealed ? 1 : 0), radius: 24, y: 12)
        .padding(20)
        .onAppear {
            if contentRevealed && emailFlow.step == .enterEmail {
                focusMacField(.email)
            }
        }
        .onChange(of: contentRevealed) { _, revealed in
            if revealed && emailFlow.step == .enterEmail {
                focusMacField(.email)
            }
        }
    }

    private var macBrandPanel: some View {
        ZStack {
            ZStack {
                Palette.raised
                LinearGradient(
                    colors: [accent.color.opacity(0.22), accent.color.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .opacity(contentRevealed ? 1 : 0)

            VStack(spacing: 0) {
                Group {
                    if logoRevealed {
                        Image("LaunchLogo")
                            .resizable()
                            .frame(width: 88, height: 88)
                            .shadow(color: Palette.navShadow, radius: 14, y: 6)
                            .matchedGeometryIfPresent(id: "launchLogo", in: logoNamespace)
                            .transition(.identity)
                    } else {
                        Color.clear
                            .frame(width: 88, height: 88)
                    }
                }

                VStack(spacing: 8) {
                    Text("DayDo")
                        .txt(28, .bold)
                        .foregroundStyle(Palette.text)

                    Text("待辦與日曆，跨裝置同步")
                        .txt(14)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 18)
                .opacity(contentRevealed ? 1 : 0)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var macFormPanel: some View {
        @Bindable var emailFlow = emailFlow

        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            Text("登入 DayDo")
                .txt(24, .bold)
                .foregroundStyle(Palette.text)

            Button {
                emailFlow.errorText = nil
                signInWithGoogle()
            } label: {
                HStack(spacing: 8) {
                    Text("G")
                        .txt(16, .bold)
                        .foregroundStyle(Palette.text)
                    Text("使用 Google 登入")
                        .txt(15, .medium)
                        .foregroundStyle(Palette.text)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.raised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.99, opacity: 0.88))
            .hoverEffect(.highlight)
            .accessibilityIdentifier("signIn.google")
            .disabled(macBusy)
            .padding(.top, 20)

            if let errorText {
                Text(errorText)
                    .txt(13)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
                Text("或")
                    .txt(13)
                    .foregroundStyle(Palette.textTertiary)
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
            }
            .padding(.vertical, 18)

            Group {
                if emailFlow.step == .enterEmail {
                    macEmailStep
                } else {
                    macCodeStep
                }
            }
            .animation(Motion.toggle(reduceMotion), value: emailFlow.step)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private var macEmailStep: some View {
        @Bindable var emailFlow = emailFlow
        let canSend = canSendMacEmailCode
        let hasError = emailFlow.errorText != nil
        let isFocused = macFocusedField == .email

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("name@example.com", text: $emailFlow.email)
                    .txt(15)
                    .foregroundStyle(Palette.text)
                    .tint(accent.color)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .focused($macFocusedField, equals: .email)
                    .submitLabel(.continue)
                    .disabled(macBusy)
                    .onChange(of: emailFlow.email) { oldValue, newValue in
                        if oldValue != newValue, emailFlow.errorText != nil {
                            emailFlow.errorText = nil
                        }
                    }
                    .onSubmit {
                        if canSend { sendMacEmailCode() }
                    }
                    .accessibilityIdentifier("emailAuth.emailField")

                if !emailFlow.email.isEmpty && !macBusy {
                    Button {
                        emailFlow.email = ""
                        emailFlow.errorText = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Palette.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除 Email")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.codeWell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        hasError ? Palette.danger : (isFocused ? accent.color : Palette.border),
                        lineWidth: isFocused || hasError ? 1.5 : 1
                    )
            )

            if let err = emailFlow.errorText {
                Text(err)
                    .txt(13)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("emailAuth.error")
            }

            Button {
                sendMacEmailCode()
            } label: {
                HStack(spacing: 6) {
                    if emailFlow.busy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accent.onAccent)
                    }
                    Text(emailFlow.busy ? "正在寄送…" : "寄送驗證碼")
                        .txt(15, .semibold)
                        .foregroundStyle(canSend ? accent.onAccent : Palette.textTertiary)
                    if !emailFlow.busy && canSend {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent.onAccent.opacity(0.75))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canSend ? accent.color : Palette.control)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.99, opacity: 0.88))
            .hoverEffect(.highlight)
            .disabled(!canSend)
            .accessibilityIdentifier("emailAuth.sendCode")
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var macCodeStep: some View {
        @Bindable var emailFlow = emailFlow
        let canSubmit = canSubmitMacEmailCode
        let hasError = emailFlow.errorText != nil
        let isFocused = macFocusedField == .code

        VStack(alignment: .leading, spacing: 0) {
            Text("已寄出 6 位數驗證碼至 \(emailFlow.sentEmail)")
                .txt(13)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let info = emailFlow.infoText {
                Text(info)
                    .txt(13)
                    .foregroundStyle(accent.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                TextField("6 位數驗證碼", text: $emailFlow.code)
                    .txt(16, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Palette.text)
                    .tint(accent.color)
                    .textContentType(.oneTimeCode)
                    .focused($macFocusedField, equals: .code)
                    .submitLabel(.done)
                    .disabled(macBusy)
                    .onChange(of: emailFlow.code) { oldValue, newValue in
                        let filtered = emailFlow.sanitizeCode(newValue)
                        guard filtered == newValue else { return }
                        if filtered != oldValue, emailFlow.errorText != nil {
                            emailFlow.errorText = nil
                        }
                        if canSubmitMacEmailCode {
                            submitMacEmailCode()
                        }
                    }
                    .onSubmit {
                        if canSubmitMacEmailCode {
                            submitMacEmailCode()
                        } else if !macBusy {
                            focusMacField(.code)
                        }
                    }
                    .onKeyPress(.escape) {
                        returnToMacEmailStep()
                        return .handled
                    }
                    .accessibilityIdentifier("emailAuth.codeField")

                if !emailFlow.code.isEmpty && !macBusy {
                    Button {
                        emailFlow.code = ""
                        emailFlow.errorText = nil
                        focusMacField(.code)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Palette.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除驗證碼")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.codeWell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        hasError ? Palette.danger : (isFocused ? accent.color : Palette.border),
                        lineWidth: isFocused || hasError ? 1.5 : 1
                    )
            )
            .padding(.top, 10)

            if let err = emailFlow.errorText {
                Text(err)
                    .txt(13)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("emailAuth.error")
            } else if emailFlow.isCurrentCodeAttempted {
                Text("這組驗證碼已試過，請輸入新的驗證碼或重新寄送")
                    .txt(13)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("emailAuth.attemptedHint")
            }

            Button {
                submitMacEmailCode()
            } label: {
                HStack(spacing: 6) {
                    if emailFlow.busy || model.isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accent.onAccent)
                    }
                    Text(emailFlow.busy || model.isSigningIn ? "正在驗證…" : "登入")
                        .txt(15, .semibold)
                        .foregroundStyle(canSubmit ? accent.onAccent : Palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canSubmit ? accent.color : Palette.control)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.99, opacity: 0.88))
            .hoverEffect(.highlight)
            .disabled(!canSubmit)
            .accessibilityIdentifier("emailAuth.submit")
            .padding(.top, 12)

            HStack {
                Button("更換信箱") {
                    returnToMacEmailStep()
                }
                .txt(13, .medium)
                .foregroundStyle(Palette.textSecondary)
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .disabled(macBusy)
                .accessibilityIdentifier("emailAuth.changeEmail")

                Spacer()

                Button("重新寄送") {
                    resendMacEmailCode()
                }
                .txt(13, .medium)
                .foregroundStyle(accent.text)
                .buttonStyle(.plain)
                .disabled(macBusy)
                .accessibilityIdentifier("emailAuth.resend")
            }
            .padding(.top, 12)
        }
    }

    private func focusMacField(_ field: MacField) {
        macFocusedField = field
        Task { @MainActor in
            await Task.yield()
            if (field == .email && emailFlow.step == .enterEmail) || (field == .code && emailFlow.step == .enterCode) {
                macFocusedField = field
            }
        }
    }

    private func returnToMacEmailStep() {
        guard !macBusy, emailFlow.step == .enterCode else { return }
        emailFlow.backToEmail()
        focusMacField(.email)
    }

    private func sendMacEmailCode() {
        errorText = nil
        Task {
            if await emailFlow.sendCode(using: model) {
                focusMacField(.code)
            } else if emailFlow.step == .enterEmail {
                focusMacField(.email)
            }
        }
    }

    private func resendMacEmailCode() {
        errorText = nil
        Task {
            _ = await emailFlow.resendCode(using: model)
            if emailFlow.step == .enterCode {
                focusMacField(.code)
            }
        }
    }

    private func submitMacEmailCode() {
        errorText = nil
        Task {
            let succeeded = await emailFlow.submitCode { email, code in
                try await performEmailSignIn(email: email, code: code, deferSwitchUntilSheetDismiss: false)
            }
            if !succeeded, emailFlow.step == .enterCode {
                focusMacField(.code)
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

    private func performEmailSignIn(email: String, code: String, deferSwitchUntilSheetDismiss: Bool) async throws {
        let credential = SyncAuthCredential.email(email: email, code: code)
        errorText = nil
        do {
            try await model.signIn(with: credential, displayName: nil, avatarUrl: nil)
        } catch let AuthError.differentAccount(auth) {
            let unsynced = await model.unsyncedChangeCount()
            let pending = PendingAccountSwitch(
                auth: auth,
                credential: credential,
                displayName: nil,
                avatarUrl: nil,
                unsyncedCount: unsynced
            )
            if deferSwitchUntilSheetDismiss {
                pendingSwitchAfterSheetDismiss = pending
            } else {
                pendingSwitch = pending
                confirmSwitchAccount = true
            }
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
            if case .email(let email, _) = pending.credential {
                let base = AuthErrorMessage.text(for: error)
                let message = base.hasSuffix("。") ? "\(base)請重新寄送驗證碼" : "\(base)。請重新寄送驗證碼"
                if Platform.isMac {
                    if emailFlow.trimmedEmail.isEmpty {
                        emailFlow.email = email
                    }
                    emailFlow.resetToEmail(error: message)
                    focusMacField(.email)
                } else {
                    errorText = message
                }
            } else {
                errorText = AuthErrorMessage.text(for: error)
            }
        }
    }
}

private struct MacWindowMinSizeBridge: UIViewRepresentable {
    let minimumSize: CGSize

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.minimumSize = minimumSize
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.minimumSize = minimumSize
        uiView.applyIfNeeded()
    }

    static func dismantleUIView(_ uiView: BridgeView, coordinator: ()) {
        uiView.restore()
    }

    final class BridgeView: UIView {
        var minimumSize: CGSize = .zero
        private weak var configuredScene: UIWindowScene?
        private var originalMinimumSize: CGSize?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                applyIfNeeded()
            }
        }

        func applyIfNeeded() {
            guard Platform.isMac,
                  let scene = window?.windowScene,
                  let restrictions = scene.sizeRestrictions else { return }
            if configuredScene !== scene {
                restore()
                configuredScene = scene
                originalMinimumSize = restrictions.minimumSize
            }
            if restrictions.minimumSize != minimumSize {
                restrictions.minimumSize = minimumSize
            }
            Platform.ensureMacWindowMinimumSize(minimumSize, in: scene)
        }

        func restore() {
            guard let scene = configuredScene,
                  let original = originalMinimumSize,
                  let restrictions = scene.sizeRestrictions else {
                configuredScene = nil
                originalMinimumSize = nil
                return
            }
            restrictions.minimumSize = original
            configuredScene = nil
            originalMinimumSize = nil
        }
    }
}
