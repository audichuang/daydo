import SwiftUI
import UIKit
import DayDoCore

/// Join a shared list by pasting an invite link (or full share message) or
/// entering a bare invite code when custom-scheme links are not tappable.
struct JoinInviteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var hasInput: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("加入共享清單").txt(17, .bold).foregroundStyle(Palette.text)
                HStack {
                    PillButton(title: "取消") { dismiss() }
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("貼上邀請連結，或直接輸入邀請碼")
                        .txt(13)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 4)

                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                        TextField("daydo://invite/… 或邀請碼", text: $input)
                            .txt(15)
                            .foregroundStyle(Palette.text)
                            .tint(accent.color)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.continue)
                            .focused($focused)
                            .onSubmit { submit() }
                            .accessibilityIdentifier("joinInvite.input")

                        if !input.isEmpty {
                            Button {
                                input = ""
                                errorText = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(Palette.control))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除邀請連結")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .card(16, color: Palette.raised)
                    .onChange(of: input) { _, _ in
                        if errorText != nil { errorText = nil }
                    }

                    if let errorText {
                        Text(errorText)
                            .txt(13)
                            .foregroundStyle(Palette.danger)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                submit()
            } label: {
                Text("查看邀請")
                    .txt(16, .bold)
                    .foregroundStyle(hasInput ? accent.onAccent : Palette.textDisabled)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(hasInput ? accent.color : Palette.separator)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasInput)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .accessibilityIdentifier("joinInvite.submit")
        }
        .background(Palette.card)
        .adaptiveSheet(detents: [.height(310)])
        .onAppear {
            if input.isEmpty,
               UIPasteboard.general.hasStrings,
               let clip = UIPasteboard.general.string,
               let link = Self.extractInviteLink(from: clip) {
                input = link
            }
            focused = true
        }
    }

    private func submit() {
        guard hasInput else { return }
        guard let code = Self.extractInviteCode(from: input) else {
            errorText = "請輸入有效的邀請連結或邀請碼"
            return
        }
        model.pendingManualInviteCode = code
        dismiss()
    }

    /// Extracts a `daydo://invite/<code>` URL if present anywhere in `raw`.
    static func extractInviteLink(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = SyncEngine.parseInviteCode(from: trimmed) {
            return "daydo://invite/\(code)"
        }
        if let range = trimmed.range(of: #"daydo://invite/[^\s]+"#, options: [.regularExpression, .caseInsensitive]),
           let code = SyncEngine.parseInviteCode(from: String(trimmed[range])) {
            return "daydo://invite/\(code)"
        }
        return nil
    }

    /// Parses either a `daydo://invite/<code>` link (standalone or embedded in
    /// share text) or a bare invite code.
    static func extractInviteCode(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let code = SyncEngine.parseInviteCode(from: trimmed) {
            return code
        }
        if let range = trimmed.range(of: #"daydo://invite/[^\s]+"#, options: [.regularExpression, .caseInsensitive]),
           let code = SyncEngine.parseInviteCode(from: String(trimmed[range])) {
            return code
        }
        let invalidChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/?#"))
        if !trimmed.contains("://"), trimmed.rangeOfCharacter(from: invalidChars) == nil {
            return trimmed
        }
        return nil
    }
}
