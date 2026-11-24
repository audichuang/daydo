import SwiftUI
import DayDoCore

struct AppearanceSettingsView: View {
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
