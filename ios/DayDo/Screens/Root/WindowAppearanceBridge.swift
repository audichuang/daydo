import SwiftUI
import UIKit
import DayDoCore

struct WindowAppearanceBridge: UIViewRepresentable {
    var style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.style = style
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.style = style
        AppearanceApplier.applyStyle(style)
        if Platform.isMac, let scene = uiView.window?.windowScene {
            Platform.hideMacWindowTitle(in: scene)
        }
    }

    final class BridgeView: UIView {
        var style: UIUserInterfaceStyle = .dark

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                window.overrideUserInterfaceStyle = style
                if Platform.isMac, let scene = window.windowScene {
                    Platform.hideMacWindowTitle(in: scene)
                }
            }
            AppearanceApplier.applyStyle(style)
        }
    }
}
