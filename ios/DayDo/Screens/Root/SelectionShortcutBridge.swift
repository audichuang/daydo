import SwiftUI
import UIKit
import DayDoCore

struct SelectionShortcutBridge: UIViewControllerRepresentable {
    var active: Bool
    var tab: MainTab
    var scope: TaskScope
    var selectedTaskId: String?
    var onMoveSelection: (Int) -> Void
    var onSpace: (String) -> Void
    var onEscape: () -> Void
    var onReturn: (String) -> Void
    var onDelete: (String) -> Void
    var onCalendarCommand: (AppModel.CalendarCommandAction) -> Void

    struct CaptureState: Equatable {
        var active: Bool
        var tab: MainTab
        var scope: TaskScope
        var selectedTaskId: String?
    }

    final class Coordinator {
        var lastState: CaptureState?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> SelectionShortcutViewController {
        SelectionShortcutViewController()
    }

    func updateUIViewController(_ vc: SelectionShortcutViewController, context: Context) {
        vc.active = active
        vc.activeTab = tab
        vc.selectedTaskId = selectedTaskId
        vc.onMoveSelection = onMoveSelection
        vc.onSpace = onSpace
        vc.onEscape = onEscape
        vc.onReturn = onReturn
        vc.onDelete = onDelete
        vc.onCalendarCommand = onCalendarCommand

        let state = CaptureState(active: active, tab: tab, scope: scope, selectedTaskId: selectedTaskId)
        guard state != context.coordinator.lastState else { return }
        context.coordinator.lastState = state
        if active {
            DispatchQueue.main.async {
                vc.claimResponderIfNeeded()
            }
        } else if vc.isFirstResponder {
            DispatchQueue.main.async {
                vc.resignFirstResponder()
            }
        }
    }
}

@MainActor
final class SelectionShortcutViewController: UIViewController {
    var active = false
    var activeTab: MainTab = .tasks
    var selectedTaskId: String?
    var onMoveSelection: ((Int) -> Void)?
    var onSpace: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onReturn: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onCalendarCommand: ((AppModel.CalendarCommandAction) -> Void)?

    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleResponderReturn), name: UITextField.textDidEndEditingNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleResponderReturn), name: UITextView.textDidEndEditingNotification, object: nil)
        if Platform.isMac {
            nc.addObserver(self, selector: #selector(handleResponderReturn), name: UIWindow.didBecomeKeyNotification, object: nil)
        }
    }

    @objc private func handleResponderReturn() {
        DispatchQueue.main.async { [weak self] in
            self?.claimResponderIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.claimResponderIfNeeded()
        }
    }

    func claimResponderIfNeeded() {
        guard active,
              let window = view.window,
              window.isKeyWindow,
              !Self.hasActiveTextInput(in: window) else { return }
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard active,
              let window = view.window,
              window.isKeyWindow,
              !Self.hasActiveTextInput(in: window) else {
            super.pressesBegan(presses, with: event)
            return
        }
        var handled = false
        for press in presses {
            guard let key = press.key,
                  key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty else { continue }
            if activeTab == .calendar && Platform.isMac {
                // Match physical keys, not characters: the user types with Zhuyin, where characters aren't D/W/M/T.
                switch key.keyCode {
                case .keyboardD:
                    onCalendarCommand?(.setMode(.day))
                    handled = true
                case .keyboardW:
                    onCalendarCommand?(.setMode(.week))
                    handled = true
                case .keyboardM:
                    onCalendarCommand?(.setMode(.month))
                    handled = true
                case .keyboardT:
                    onCalendarCommand?(.today)
                    handled = true
                case .keyboardEscape:
                    // Closes the calendar's detail pane; skipped while a text field is
                    // active (guard above), so Esc still cancels Zhuyin composition there.
                    onEscape?()
                    handled = true
                default:
                    break
                }
                continue
            }
            guard activeTab == .tasks else { continue }
            switch key.keyCode {
            case .keyboardUpArrow where Platform.isMac:
                onMoveSelection?(-1)
                handled = true
            case .keyboardDownArrow where Platform.isMac:
                onMoveSelection?(1)
                handled = true
            case .keyboardSpacebar where Platform.isMac:
                if let selectedTaskId {
                    onSpace?(selectedTaskId)
                    handled = true
                }
            case .keyboardEscape where Platform.isMac:
                if selectedTaskId != nil {
                    onEscape?()
                    handled = true
                }
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
                if let selectedTaskId {
                    onDelete?(selectedTaskId)
                    handled = true
                }
            case .keyboardReturnOrEnter:
                if let selectedTaskId {
                    onReturn?(selectedTaskId)
                    handled = true
                }
            default:
                break
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    private static func hasActiveTextInput(in view: UIView) -> Bool {
        if (view is UITextField || view is UITextView) && view.isFirstResponder { return true }
        return view.subviews.contains { hasActiveTextInput(in: $0) }
    }
}
