import Observation
import SwiftUI
import DayDoCore

final class AnchorViewBox {
    weak var view: UIView?

    @MainActor
    func windowFrame() -> CGRect {
        guard let view, let window = view.window else { return .zero }
        return view.convert(view.bounds, to: window)
    }
}

struct AnchorFrameProbe: UIViewRepresentable {
    let box: AnchorViewBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        box.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        box.view = uiView
    }
}

/// Button wrapper that reads its window frame at click time on Mac so a
/// single `UIPopoverPresentationController` can anchor to the clicked task
/// without writing `@State` on every scroll frame.
struct CalendarTaskAnchorButton<Label: View>: View {
    var action: (CGRect) -> Void
    @ViewBuilder var label: () -> Label
    @State private var anchorBox = AnchorViewBox()

    var body: some View {
        Button {
            action(Platform.isMac ? anchorBox.windowFrame() : .zero)
        } label: {
            label()
        }
        .background {
            if Platform.isMac {
                AnchorFrameProbe(box: anchorBox)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct CalendarTaskTapAnchor<Content: View>: View {
    var onTap: (CGRect) -> Void
    @ViewBuilder var content: () -> Content
    @State private var anchorBox = AnchorViewBox()

    var body: some View {
        content()
            .onTapGesture {
                onTap(Platform.isMac ? anchorBox.windowFrame() : .zero)
            }
            .background {
                if Platform.isMac {
                    AnchorFrameProbe(box: anchorBox)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
