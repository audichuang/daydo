import Observation
import SwiftUI
import UIKit
import DayDoCore

/// Shared two-step email verification code state and logic used by both
/// `EmailCodeSheet` (iOS/iPadOS sign-in and account linking) and the inline
/// Mac sign-in card in `SignInView`.
@MainActor
@Observable
final class EmailCodeFlow {
    enum Step {
        case enterEmail
        case enterCode
    }

    var step: Step = .enterEmail
    var email = ""
    private(set) var sentEmail = ""
    var code = ""
    private(set) var busy = false
    var errorText: String?
    var infoText: String?
    private(set) var attemptedCodes: Set<String> = []

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSendCode: Bool {
        guard !busy else { return false }
        let parts = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !trimmedEmail.contains(where: \.isWhitespace)
    }

    var isCurrentCodeAttempted: Bool {
        code.count == 6 && attemptedCodes.contains(code)
    }

    /// Single submission gate shared by auto-submit (Mac), Return/Enter, and the submit button.
    var canSubmitCode: Bool {
        !busy && code.count == 6 && !isCurrentCodeAttempted
    }

    @discardableResult
    func sanitizeCode(_ raw: String) -> String {
        let filtered = String(raw.filter(\.isNumber).prefix(6))
        if filtered != code {
            code = filtered
        }
        return filtered
    }

    func resetToEmail(error: String? = nil) {
        guard !busy else { return }
        errorText = error
        infoText = nil
        code = ""
        attemptedCodes.removeAll()
        step = .enterEmail
    }

    func backToEmail() {
        resetToEmail(error: nil)
    }

    func sendCode(using model: AppModel) async -> Bool {
        await sendCode { email in
            try await model.startEmailSignIn(email: email)
        }
    }

    func sendCode(_ start: (_ email: String) async throws -> Void) async -> Bool {
        let target = trimmedEmail
        guard canSendCode else { return false }
        busy = true
        errorText = nil
        infoText = nil
        defer { busy = false }
        do {
            try await start(target)
            sentEmail = target
            code = ""
            attemptedCodes.removeAll()
            step = .enterCode
            return true
        } catch {
            errorText = AuthErrorMessage.text(for: error)
            return false
        }
    }

    func resendCode(using model: AppModel) async -> Bool {
        await resendCode { email in
            try await model.startEmailSignIn(email: email)
        }
    }

    func resendCode(_ start: (_ email: String) async throws -> Void) async -> Bool {
        guard !busy, !sentEmail.isEmpty else { return false }
        busy = true
        errorText = nil
        infoText = nil
        defer { busy = false }
        do {
            try await start(sentEmail)
            code = ""
            attemptedCodes.removeAll()
            infoText = "已重新寄送驗證碼。"
            return true
        } catch {
            errorText = AuthErrorMessage.text(for: error)
            return false
        }
    }

    func submitCode(_ action: (_ email: String, _ code: String) async throws -> Void) async -> Bool {
        guard canSubmitCode else { return false }
        let targetEmail = sentEmail
        let targetCode = code
        attemptedCodes.insert(targetCode)
        busy = true
        errorText = nil
        infoText = nil
        defer { busy = false }
        do {
            try await action(targetEmail, targetCode)
            return true
        } catch {
            if !Self.isRejectedCodeError(error) {
                attemptedCodes.remove(targetCode)
            }
            errorText = AuthErrorMessage.text(for: error)
            return false
        }
    }

    private static func isRejectedCodeError(_ error: Error) -> Bool {
        if let authError = error as? AuthError, case .invalidCode = authError {
            return true
        }
        return false
    }
}

/// Shared two-step email verification code sheet for both sign-in (`SignInView`)
/// and account linking (`SettingsScreen`).
struct EmailCodeSheet: View {
    enum Mode {
        case signIn
        case link
    }

    private enum Field: Hashable {
        case email
        case code
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    /// Called with normalized email and 6-digit code. Returning normally dismisses the sheet;
    /// throwing displays the error inline inside the sheet.
    let onSubmitCode: (_ email: String, _ code: String) async throws -> Void

    @State private var flow = EmailCodeFlow()
    @FocusState private var focusedField: Field?

    private var title: String {
        mode == .signIn ? "使用 Email 登入" : "連結 Email"
    }

    private var submitTitle: String {
        mode == .signIn ? "登入" : "完成連結"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .txt(17, .bold)
                    .foregroundStyle(Palette.text)
                HStack {
                    PillButton(title: "取消") { dismiss() }
                        .disabled(flow.busy)
                        .accessibilityIdentifier("emailAuth.cancel")
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .frame(height: 68)

            ViewThatFits(in: .vertical) {
                formContent
                ScrollView {
                    formContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.card)
        .adaptiveSheet(detents: [.large])
        .interactiveDismissDisabled(flow.busy)
        .onAppear {
            focusedField = .email
        }
    }

    @ViewBuilder
    private var formContent: some View {
        @Bindable var flow = flow
        VStack(alignment: .leading, spacing: 14) {
            if let errorText = flow.errorText {
                Text(errorText)
                    .txt(13)
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(12, color: Palette.raised)
                    .accessibilityIdentifier("emailAuth.error")
            }

            if flow.step == .enterEmail {
                Text("輸入你的 Email，我們會寄送 6 位數驗證碼。")
                    .txt(14)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 2)

                HStack(spacing: 10) {
                    TextField("name@example.com", text: $flow.email)
                        .txt(16)
                        .foregroundStyle(Palette.text)
                        .tint(accent.color)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                        .focused($focusedField, equals: .email)
                        .submitLabel(.continue)
                        .onSubmit {
                            if flow.canSendCode { sendCode() }
                        }
                        .accessibilityIdentifier("emailAuth.emailField")

                    if !flow.email.isEmpty && !flow.busy {
                        Button { flow.email = "" } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Palette.control))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除 Email")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .card(16, color: Palette.raised)

                Button {
                    sendCode()
                } label: {
                    HStack(spacing: 8) {
                        if flow.busy {
                            ProgressView().tint(accent.onAccent)
                        }
                        Text(flow.busy ? "正在寄送…" : "寄送驗證碼")
                            .txt(16, .semibold)
                            .foregroundStyle(flow.canSendCode ? accent.onAccent : Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(flow.canSendCode ? accent.color : Palette.control)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .hoverEffect(.highlight)
                .disabled(!flow.canSendCode)
                .accessibilityIdentifier("emailAuth.sendCode")
            } else {
                Text("已寄出 6 位數驗證碼至 \(flow.sentEmail)，10 分鐘內有效。")
                    .txt(14)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 2)

                if let infoText = flow.infoText {
                    Text(infoText)
                        .txt(13)
                        .foregroundStyle(accent.text)
                        .padding(.horizontal, 2)
                }

                HStack(spacing: 10) {
                    TextField("6 位數驗證碼", text: $flow.code)
                        .txt(20, .semibold)
                        .foregroundStyle(Palette.text)
                        .tint(accent.color)
                        .keyboardType(UIDevice.current.userInterfaceIdiom == .pad ? .numbersAndPunctuation : .numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .code)
                        .submitLabel(.done)
                        .onChange(of: flow.code) { _, newValue in
                            _ = flow.sanitizeCode(newValue)
                        }
                        .onSubmit {
                            if flow.canSubmitCode { submitCode() }
                        }
                        .accessibilityIdentifier("emailAuth.codeField")

                    if !flow.code.isEmpty && !flow.busy {
                        Button { flow.code = "" } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Palette.control))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除驗證碼")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .card(16, color: Palette.raised)

                Button {
                    submitCode()
                } label: {
                    HStack(spacing: 8) {
                        if flow.busy {
                            ProgressView().tint(accent.onAccent)
                        }
                        Text(flow.busy ? "正在驗證…" : submitTitle)
                            .txt(16, .semibold)
                            .foregroundStyle(flow.canSubmitCode ? accent.onAccent : Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(flow.canSubmitCode ? accent.color : Palette.control)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .hoverEffect(.highlight)
                .disabled(!flow.canSubmitCode)
                .accessibilityIdentifier("emailAuth.submit")

                HStack {
                    Button("更換信箱") {
                        flow.backToEmail()
                        focusedField = .email
                    }
                    .txt(14, .medium)
                    .foregroundStyle(Palette.textSecondary)
                    .buttonStyle(.plain)
                    .disabled(flow.busy)
                    .accessibilityIdentifier("emailAuth.changeEmail")

                    Spacer()

                    Button("重新寄送") {
                        resendCode()
                    }
                    .txt(14, .medium)
                    .foregroundStyle(accent.text)
                    .buttonStyle(.plain)
                    .disabled(flow.busy)
                    .accessibilityIdentifier("emailAuth.resend")
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 28)
    }

    private func sendCode() {
        Task {
            if await flow.sendCode(using: model) {
                focusedField = .code
            }
        }
    }

    private func resendCode() {
        Task {
            if await flow.resendCode(using: model) {
                focusedField = .code
            }
        }
    }

    private func submitCode() {
        Task {
            if await flow.submitCode(onSubmitCode) {
                dismiss()
            }
        }
    }
}
