import SwiftUI
import UIKit
import DayDoCore

/// Floating glass navigation: 任務／日曆／搜尋／設定 (62pt high, 30pt from bottom).
struct BottomNav: View {
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var tab: MainTab
    var todayDay: Int
    @Namespace private var selectionNamespace
    @State private var bounceCount: [MainTab: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            item(.tasks, "任務", "checkmark.square", selected: "checkmark.square.fill")
            item(.calendar, "日曆", "calendar")
            item(.search, "搜尋", "magnifyingglass")
            item(.settings, "設定", "gearshape", selected: "gearshape.fill")
        }
        .padding(5)
        .frame(height: 62)
        .glassEffect(.regular.tint(Palette.navGlassTint), in: .capsule)
        .shadow(color: Palette.navShadow, radius: 12, y: 8)
        .animation(Motion.tab(reduceMotion), value: tab)
    }

    func item(_ t: MainTab, _ label: String, _ icon: String, selected: String? = nil) -> some View {
        let on = tab == t
        return Button {
            if tab != t {
                tab = t
            }
            if !reduceMotion {
                bounceCount[t, default: 0] += 1
            }
        } label: {
            Image(systemName: on ? (selected ?? icon) : icon)
                .font(.system(size: 22, weight: on ? .semibold : .regular))
                .symbolEffect(.bounce, value: bounceCount[t, default: 0])
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? accent.text : Palette.textNav)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if on {
                        Capsule()
                            .fill(Palette.navSelection)
                            .matchedGeometryIfPresent(id: "bottomNavSelection", in: reduceMotion ? nil : selectionNamespace)
                            .transition(.opacity)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.press(scale: 0.95, opacity: 0.9))
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
