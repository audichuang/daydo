import SwiftUI
import UIKit
import DayDoCore

/// Shared two-step email verification code sheet for both sign-in (`SignInView`)
/// and account linking (`SettingsScreen`).
struct EmailCodeSheet: View {
    enum Mode {
        case signIn
        case link
    }

    private enum Step {
        case enterEmail
        case enterCode
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

    @State private var step: Step = .enterEmail
    @State private var email = ""
    @State private var sentEmail = ""
    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var infoText: String?
    @FocusState private var focusedField: Field?

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSendCode: Bool {
        guard !busy else { return false }
        let parts = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !trimmedEmail.contains(where: \.isWhitespace)
    }

    private var canSubmitCode: Bool {
        !busy && code.count == 6
    }

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
                        .disabled(busy)
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
        .interactiveDismissDisabled(busy)
        .onAppear {
            focusedField = .email
        }
    }

    @ViewBuilder
    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let errorText {
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

            if step == .enterEmail {
                Text("輸入你的 Email，我們會寄送 6 位數驗證碼。")
                    .txt(14)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 2)

                HStack(spacing: 10) {
                    TextField("name@example.com", text: $email)
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
                            if canSendCode { sendCode() }
                        }
                        .accessibilityIdentifier("emailAuth.emailField")

                    if !email.isEmpty && !busy {
                        Button { email = "" } label: {
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
                        if busy {
                            ProgressView().tint(accent.onAccent)
                        }
                        Text(busy ? "正在寄送…" : "寄送驗證碼")
                            .txt(16, .semibold)
                            .foregroundStyle(canSendCode ? accent.onAccent : Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSendCode ? accent.color : Palette.control)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .hoverEffect(.highlight)
                .disabled(!canSendCode)
                .accessibilityIdentifier("emailAuth.sendCode")
            } else {
                Text("已寄出 6 位數驗證碼至 \(sentEmail)，10 分鐘內有效。")
                    .txt(14)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 2)

                if let infoText {
                    Text(infoText)
                        .txt(13)
                        .foregroundStyle(accent.text)
                        .padding(.horizontal, 2)
                }

                HStack(spacing: 10) {
                    TextField("6 位數驗證碼", text: $code)
                        .txt(20, .semibold)
                        .foregroundStyle(Palette.text)
                        .tint(accent.color)
                        .keyboardType(UIDevice.current.userInterfaceIdiom == .pad ? .numbersAndPunctuation : .numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .code)
                        .submitLabel(.done)
                        .onChange(of: code) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(6))
                            if filtered != newValue {
                                code = filtered
                            }
                        }
                        .onSubmit {
                            if canSubmitCode { submitCode() }
                        }
                        .accessibilityIdentifier("emailAuth.codeField")

                    if !code.isEmpty && !busy {
                        Button { code = "" } label: {
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
                        if busy {
                            ProgressView().tint(accent.onAccent)
                        }
                        Text(busy ? "正在驗證…" : submitTitle)
                            .txt(16, .semibold)
                            .foregroundStyle(canSubmitCode ? accent.onAccent : Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSubmitCode ? accent.color : Palette.control)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .hoverEffect(.highlight)
                .disabled(!canSubmitCode)
                .accessibilityIdentifier("emailAuth.submit")

                HStack {
                    Button("更換信箱") {
                        errorText = nil
                        infoText = nil
                        code = ""
                        step = .enterEmail
                        focusedField = .email
                    }
                    .txt(14, .medium)
                    .foregroundStyle(Palette.textSecondary)
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityIdentifier("emailAuth.changeEmail")

                    Spacer()

                    Button("重新寄送") {
                        resendCode()
                    }
                    .txt(14, .medium)
                    .foregroundStyle(accent.text)
                    .buttonStyle(.plain)
                    .disabled(busy)
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
        let target = trimmedEmail
        guard canSendCode else { return }
        busy = true
        errorText = nil
        infoText = nil
        Task {
            defer { busy = false }
            do {
                try await model.startEmailSignIn(email: target)
                sentEmail = target
                code = ""
                step = .enterCode
                focusedField = .code
            } catch {
                errorText = AuthErrorMessage.text(for: error)
            }
        }
    }

    private func resendCode() {
        guard !busy, !sentEmail.isEmpty else { return }
        busy = true
        errorText = nil
        infoText = nil
        Task {
            defer { busy = false }
            do {
                try await model.startEmailSignIn(email: sentEmail)
                code = ""
                infoText = "已重新寄送驗證碼。"
                focusedField = .code
            } catch {
                errorText = AuthErrorMessage.text(for: error)
            }
        }
    }

    private func submitCode() {
        guard canSubmitCode else { return }
        let targetEmail = sentEmail
        let targetCode = code
        busy = true
        errorText = nil
        infoText = nil
        Task {
            defer { busy = false }
            do {
                try await onSubmitCode(targetEmail, targetCode)
                dismiss()
            } catch {
                errorText = AuthErrorMessage.text(for: error)
            }
        }
    }
}
