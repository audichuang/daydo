import SwiftUI
import UIKit
import DayDoCore

/// Top toolbar shared by the main screens: drawer button left, a glass
/// capsule of actions right; content scrolls under a fading gradient.
struct ScreenHeader<Center: View, Trailing: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            GlassIconButton(systemName: "line.3.horizontal", label: "開啟清單抽屜") {
                withAnimation(Motion.drawer(reduceMotion)) { model.drawerOpen = true }
            }
            Spacer()
            center
            Spacer()
            HStack(spacing: 0) { trailing }
                .padding(.horizontal, 2)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: Palette.background, location: 0.55), .init(color: Palette.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}

struct HeaderAction: View {
    var systemName: String
    var label: String
    var tint: Color = Palette.text
    var action: () -> Void
    var body: some View {
        if Platform.isMac {
            Button(action: action) {
                Label(label, systemImage: systemName)
            }
            .labelStyle(.iconOnly)
            .tint(nil)
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: systemName).font(.system(size: 18, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .hoverEffect(.highlight)
            .accessibilityLabel(label)
        }
    }
}
