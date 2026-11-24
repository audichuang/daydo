import SwiftUI
import UIKit
import DayDoCore

extension View {
    @ViewBuilder
    func matchedGeometryIfPresent<ID: Hashable>(id: ID, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Sets `UIScrollView.scrollsToTop` on the enclosing scroll view so hidden
    /// resident tabs do not compete with the active tab's status-bar scroll-to-top.
    func enclosingScrollsToTop(_ enabled: Bool) -> some View {
        background(
            ScrollsToTopBridge(enabled: enabled)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

struct ScrollsToTopBridge: UIViewRepresentable {
    var enabled: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.scrollsToTopEnabled = enabled
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.scrollsToTopEnabled = enabled
        uiView.apply()
    }

    final class ProbeView: UIView {
        var scrollsToTopEnabled = true

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            apply()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            enclosingScrollView?.scrollsToTop = scrollsToTopEnabled
        }
    }
}
