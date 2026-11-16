import SwiftUI

/// Role-named animation curve with an explicit reduced-motion fallback.
struct MotionToken: Sendable {
    let full: Animation
    let reduced: Animation

    func callAsFunction(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : full
    }
}

/// Centralized motion tokens for DayDo UI animations and shared transitions.
enum Motion {
    /// Tactile button press scale and opacity feedback.
    static let press = MotionToken(
        full: .spring(response: 0.24, dampingFraction: 0.72),
        reduced: .easeOut(duration: 0.1)
    )

    /// Bottom navigation selection pill and tab switching.
    static let tab = MotionToken(
        full: .spring(response: 0.32, dampingFraction: 0.78),
        reduced: .easeOut(duration: 0.15)
    )

    /// Crossfade between root tab screens.
    static let tabContent = MotionToken(
        full: .easeInOut(duration: 0.18),
        reduced: .easeOut(duration: 0.15)
    )

    /// Drawer overlay open, close, and edge-drag snap.
    static let drawer = MotionToken(
        full: .spring(response: 0.32, dampingFraction: 0.86),
        reduced: .easeOut(duration: 0.2)
    )

    /// Swipe row reset and drawer drag cancel.
    static let rowSwipe = MotionToken(
        full: .spring(response: 0.3, dampingFraction: 0.82),
        reduced: .easeOut(duration: 0.15)
    )

    /// Swipeable drawer list row settling onto an action stop.
    static let rowSwipeSettle = MotionToken(
        full: .spring(response: 0.34, dampingFraction: 0.78),
        reduced: .easeOut(duration: 0.15)
    )

    /// Swipe-revealed action button pop-in/out.
    static let popup = MotionToken(
        full: .spring(response: 0.28, dampingFraction: 0.68),
        reduced: .easeOut(duration: 0.15)
    )

    /// List row insert/remove/reflow, section collapse, and calendar month/week collapse.
    static let layout = MotionToken(
        full: .spring(response: 0.34, dampingFraction: 0.86),
        reduced: .easeOut(duration: 0.15)
    )

    /// Time for a `Motion.layout` removal to finish, plus margin for the list reload.
    static func layoutSettle(_ reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(350) : .milliseconds(750)
    }

    /// Calendar page shift and horizontal swipe commit.
    static let page = MotionToken(
        full: .spring(response: 0.34, dampingFraction: 0.86),
        reduced: .easeOut(duration: 0.18)
    )

    /// Calendar horizontal swipe snap-back when cancelled.
    static let pageSnapBack = MotionToken(
        full: .spring(response: 0.34, dampingFraction: 0.78),
        reduced: .easeOut(duration: 0.15)
    )

    /// Task row completion text/opacity state change.
    static let check = MotionToken(
        full: .spring(response: 0.3, dampingFraction: 0.75),
        reduced: .easeOut(duration: 0.15)
    )

    /// Checkbox checkmark bounce.
    static let checkbox = MotionToken(
        full: .spring(response: 0.3, dampingFraction: 0.62),
        reduced: .easeOut(duration: 0.15)
    )

    /// Small UI state toggles, disclosures, and sheet detent/page switches.
    static let toggle = MotionToken(
        full: .snappy,
        reduced: .easeOut(duration: 0.15)
    )

    /// Numeric count badge and subtitle transitions.
    static let count = MotionToken(
        full: .snappy(duration: 0.25),
        reduced: .easeOut(duration: 0.15)
    )

    /// Splash dismiss when already signed in.
    static let launch = MotionToken(
        full: .easeOut(duration: 0.45),
        reduced: .easeOut(duration: 0.25)
    )

    /// Splash-to-sign-in logo handoff.
    static let signIn = MotionToken(
        full: .spring(duration: 0.45, bounce: 0.1),
        reduced: .easeOut(duration: 0.25)
    )

    static func rowTransition(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
            )
    }

    static func expandTransition(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}
