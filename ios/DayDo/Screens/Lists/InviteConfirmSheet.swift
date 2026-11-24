import SwiftUI
import DayDoCore

struct InviteConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss

    var prompt: PendingInvitePrompt

    @State private var accepting = false
    @State private var acceptError: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
#if DEBUG
                Text("清單邀請").txt(17, .bold).foregroundStyle(Palette.text)
                    .accessibilityValue("appear:\(model.debugInviteAppearCount)")
#else
                Text("清單邀請").txt(17, .bold).foregroundStyle(Palette.text)
#endif
                HStack {
                    PillButton(title: "關閉") {
                        model.invitePrompt = nil
                        dismiss()
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 10)

            if prompt.isLoading {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView().tint(Palette.textSecondary)
                    Text("正在讀取邀請資訊…")
                        .txt(14)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 20)
                Spacer()
            } else if let info = prompt.info {
                ScrollView {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(accent.soft)
                                .frame(width: 56, height: 56)
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(accent.text)
                        }

                        Text("\(info.inviterName) 邀請你加入「\(info.projectName)」")
                            .txt(19, .bold)
                            .foregroundStyle(Palette.text)
                            .multilineTextAlignment(.center)

                        VStack(spacing: 0) {
                            infoRow("權限", value: info.role == "viewer" ? "唯讀" : "可編輯", last: false)
                            infoRow("有效期限", value: expiryText(info.expiresAt), last: true)
                        }
                        .padding(.horizontal, 14)
                        .card(16, color: Palette.raised)

                        if let acceptError {
                            Text(acceptError)
                                .txt(13)
                                .foregroundStyle(Palette.danger)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)

                VStack(spacing: 10) {
                    Button {
                        accept()
                    } label: {
                        HStack(spacing: 8) {
                            if accepting {
                                ProgressView().tint(accent.onAccent)
                            }
                            Text(accepting ? "加入中…" : "加入清單")
                                .txt(16, .bold)
                                .foregroundStyle(accent.onAccent)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.color))
                    }
                    .buttonStyle(.plain)
                    .disabled(accepting)
                    .accessibilityIdentifier("invite.accept")

                    Button("略過") {
                        model.invitePrompt = nil
                        dismiss()
                    }
                    .txt(15, .medium)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
                    .disabled(accepting)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            } else {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Palette.danger)
                    Text(prompt.error ?? "邀請連結無效或已過期")
                        .txt(15)
                        .foregroundStyle(Palette.textBody)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                Spacer()
                PillButton(title: "好") {
                    model.invitePrompt = nil
                    dismiss()
                }
                .padding(.bottom, 20)
            }
        }
        .background(Palette.card)
        .adaptiveSheet(detents: [.height(480), .large], dragIndicator: .visible, macSize: CGSize(width: 420, height: 420))
#if DEBUG
        .onAppear {
            model.debugInviteAppearCount += 1
        }
#endif
    }

    private func infoRow(_ label: String, value: String, last: Bool) -> some View {
        HStack {
            Text(label).txt(15).foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(value).txt(15, .semibold).foregroundStyle(Palette.text)
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle().fill(Palette.separatorSoft).frame(height: 1)
            }
        }
    }

    private func expiryText(_ expiresAt: EpochMillis) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(epochMillis: expiresAt))
    }

    private func accept() {
        acceptError = nil
        accepting = true
        let code = prompt.code
        Task {
            defer { accepting = false }
            do {
                try await model.acceptPendingInvite(code: code)
                dismiss()
            } catch {
                acceptError = error.localizedDescription
            }
        }
    }
}
