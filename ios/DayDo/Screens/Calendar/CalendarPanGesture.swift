import Observation
import SwiftUI
import DayDoCore

/// UIKit pan recognizer for calendar horizontal paging and vertical grid
/// collapse/expand, keeping ScrollView vertical scrolling and taps responsive.
struct CalendarPanGesture: UIGestureRecognizerRepresentable {
    var allowLeftEdgeRightward: Bool
    var canBegin: () -> Bool = { true }
    var allowVertical: () -> Bool
    var verticalShouldBegin: (CGFloat) -> Bool
    var onHorizontalChanged: (CGFloat) -> Void
    var onHorizontalEnded: (CGFloat, CGFloat) -> Void
    var onVerticalChanged: ((CGFloat) -> Void)? = nil
    var onVerticalEnded: ((CGFloat, CGFloat) -> Void)? = nil

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(
            allowLeftEdgeRightward: allowLeftEdgeRightward,
            canBegin: canBegin,
            allowVertical: allowVertical,
            verticalShouldBegin: verticalShouldBegin,
            onHorizontalChanged: onHorizontalChanged,
            onHorizontalEnded: onHorizontalEnded,
            onVerticalChanged: onVerticalChanged,
            onVerticalEnded: onVerticalEnded
        )
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        if Platform.isMac {
            pan.allowedScrollTypesMask = .continuous
        }
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.allowLeftEdgeRightward = allowLeftEdgeRightward
        context.coordinator.canBegin = canBegin
        context.coordinator.allowVertical = allowVertical
        context.coordinator.verticalShouldBegin = verticalShouldBegin
        context.coordinator.onHorizontalChanged = onHorizontalChanged
        context.coordinator.onHorizontalEnded = onHorizontalEnded
        context.coordinator.onVerticalChanged = onVerticalChanged
        context.coordinator.onVerticalEnded = onVerticalEnded
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let t = recognizer.translation(in: recognizer.view)
        let v = recognizer.velocity(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            switch context.coordinator.activeAxis {
            case .horizontal: onHorizontalChanged(t.x)
            case .vertical: onVerticalChanged?(t.y)
            case .none: break
            }
        case .ended, .cancelled, .failed:
            let axis = context.coordinator.activeAxis
            context.coordinator.activeAxis = .none
            switch axis {
            case .horizontal: onHorizontalEnded(t.x, v.x)
            case .vertical: onVerticalEnded?(t.y, v.y)
            case .none: break
            }
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        enum Axis { case none, horizontal, vertical }
        var activeAxis: Axis = .none
        var allowLeftEdgeRightward: Bool
        var canBegin: () -> Bool
        var allowVertical: () -> Bool
        var verticalShouldBegin: (CGFloat) -> Bool
        var onHorizontalChanged: (CGFloat) -> Void
        var onHorizontalEnded: (CGFloat, CGFloat) -> Void
        var onVerticalChanged: ((CGFloat) -> Void)?
        var onVerticalEnded: ((CGFloat, CGFloat) -> Void)?

        init(
            allowLeftEdgeRightward: Bool,
            canBegin: @escaping () -> Bool,
            allowVertical: @escaping () -> Bool,
            verticalShouldBegin: @escaping (CGFloat) -> Bool,
            onHorizontalChanged: @escaping (CGFloat) -> Void,
            onHorizontalEnded: @escaping (CGFloat, CGFloat) -> Void,
            onVerticalChanged: ((CGFloat) -> Void)?,
            onVerticalEnded: ((CGFloat, CGFloat) -> Void)?
        ) {
            self.allowLeftEdgeRightward = allowLeftEdgeRightward
            self.canBegin = canBegin
            self.allowVertical = allowVertical
            self.verticalShouldBegin = verticalShouldBegin
            self.onHorizontalChanged = onHorizontalChanged
            self.onHorizontalEnded = onHorizontalEnded
            self.onVerticalChanged = onVerticalChanged
            self.onVerticalEnded = onVerticalEnded
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard canBegin(), let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            if abs(v.x) > abs(v.y) * 1.25 {
                let startX = pan.location(in: nil).x - pan.translation(in: nil).x
                if !allowLeftEdgeRightward && startX <= DrawerMetrics.edgeWidth && v.x > 0 {
                    return false
                }
                activeAxis = .horizontal
                return true
            }
            if allowVertical(), abs(v.y) > abs(v.x) * 1.25, verticalShouldBegin(v.y) {
                activeAxis = .vertical
                return true
            }
            return false
        }
    }
}
