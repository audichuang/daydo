import SwiftUI
import DayDoCore

/// Sheet for setting the current user's display name and avatar color:
/// - `requiredPrompt`: shown once after sign-in / launch when the name is still "我".
/// - `edit`: opened from Settings -> account row to rename or recolor.
struct MeProfileSheet: View {
    enum Mode {
        case requiredPrompt
        case edit
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss

    var mode: Mode

    @State private var name = ""
    @State private var selectedColor = Member.avatarColors[0]
    @State private var originalName = ""
    @State private var originalColor = Member.avatarColors[0]
    @State private var saving = false
    @FocusState private var focused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard !saving, !trimmedName.isEmpty else { return false }
        switch mode {
        case .requiredPrompt:
            return true
        case .edit:
            return trimmedName != originalName || selectedColor != originalColor
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(mode == .requiredPrompt ? "你的名字" : "個人資料")
                    .txt(17, .bold)
                    .foregroundStyle(Palette.text)
                HStack {
                    if mode == .edit {
                        PillButton(title: "取消") { dismiss() }
                            .accessibilityIdentifier("meProfile.cancel")
                    }
                    Spacer()
                    PillButton(title: mode == .requiredPrompt ? "完成" : "儲存", kind: canSave ? .primary : .disabled) {
                        save()
                    }
                    .accessibilityIdentifier("meProfile.submit")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .frame(height: 68)

            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: selectedColor))
                            .frame(width: 68, height: 68)
                        if trimmedName.isEmpty {
                            Image(systemName: "person.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Palette.onLightFill)
                        } else {
                            Text(Member.makeInitial(from: trimmedName))
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(Palette.onLightFill)
                        }
                    }
                    .padding(.top, 4)

                    HStack(spacing: 10) {
                        TextField("輸入你的名字", text: $name)
                            .txt(17, .semibold)
                            .foregroundStyle(Palette.text)
                            .tint(accent.color)
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit {
                                if canSave { save() }
                            }
                            .onChange(of: name) { _, v in
                                if v.count > 30 {
                                    name = String(v.prefix(30))
                                }
                            }
                            .accessibilityIdentifier("meProfile.nameField")

                        if !name.isEmpty {
                            Button { name = "" } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Palette.control))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除名字")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .card(16, color: Palette.raised)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("頭像顏色")
                            .txt(13, .semibold)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 6)

                        HStack(spacing: 0) {
                            ForEach(Member.avatarColors, id: \.self) { hex in
                                let selected = selectedColor == hex
                                Button { selectedColor = hex } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 26, height: 26)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(selected ? Palette.text : .clear, lineWidth: 2))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(hex)
                                .accessibilityIdentifier("meProfile.color.\(hex)")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                    .card(16, color: Palette.raised)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.card)
        .adaptiveSheet(detents: [.medium, .large])
        .interactiveDismissDisabled(mode == .requiredPrompt)
        .onAppear {
            let me = model.me
            let defaultPaletteColor = me.map { Member.defaultColor(for: $0.id) } ?? Member.avatarColors[0]
            let currentColor: String
            if let me, me.color != Member.legacyDefaultColor, Member.avatarColors.contains(me.color) {
                currentColor = me.color
            } else {
                currentColor = defaultPaletteColor
            }
            selectedColor = currentColor
            originalColor = currentColor

            if mode == .edit {
                let currentName = me?.name ?? ""
                name = currentName
                originalName = currentName
            } else {
                name = ""
                originalName = ""
            }
            focused = true
        }
    }

    private func save() {
        let targetName = trimmedName
        let targetColor = selectedColor
        guard !targetName.isEmpty, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            if await model.perform({ try await $0.updateMe(name: targetName, color: targetColor) }) != nil {
                if mode == .requiredPrompt {
                    model.showingMeNamePrompt = false
                }
                dismiss()
            }
        }
    }
}
