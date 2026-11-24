import MachO
import os
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications
import DayDoCore

@MainActor
final class DatabaseSuspensionCoordinator {
    typealias ExpirationHandler = @MainActor @Sendable () -> Void
    typealias BeginBackgroundTask = (_ name: String?, _ expirationHandler: @escaping ExpirationHandler) -> UIBackgroundTaskIdentifier
    typealias EndBackgroundTask = (_ identifier: UIBackgroundTaskIdentifier) -> Void

    private let beginBackgroundTask: BeginBackgroundTask
    private let endBackgroundTask: EndBackgroundTask
    private let suspend: () -> Void
    private let resume: () -> Void

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isSuspended = false

    init(
        beginBackgroundTask: @escaping BeginBackgroundTask = { name, handler in
            UIApplication.shared.beginBackgroundTask(withName: name) {
                MainActor.assumeIsolated {
                    handler()
                }
            }
        },
        endBackgroundTask: @escaping EndBackgroundTask = { id in
            UIApplication.shared.endBackgroundTask(id)
        },
        suspend: @escaping () -> Void = DayDoStorage.suspendDatabaseAccess,
        resume: @escaping () -> Void = DayDoStorage.resumeDatabaseAccess
    ) {
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.suspend = suspend
        self.resume = resume
    }

    func enterBackground() {
        guard backgroundTaskID == .invalid, !isSuspended else { return }
        var finishedDuringBegin = false
        var returnedID: UIBackgroundTaskIdentifier = .invalid
        let taskID = beginBackgroundTask("DayDo.DatabaseSuspension") { [weak self] in
            guard let self else { return }
            if self.backgroundTaskID != .invalid {
                self.finishExpiration(taskID: self.backgroundTaskID)
            } else if returnedID == .invalid {
                finishedDuringBegin = true
                self.suspendIfNeeded()
            }
        }
        returnedID = taskID
        if finishedDuringBegin {
            if taskID != .invalid {
                endBackgroundTask(taskID)
            }
            return
        }
        if taskID == .invalid {
            suspendIfNeeded()
            return
        }
        backgroundTaskID = taskID
    }

    func leaveBackground() {
        if backgroundTaskID != .invalid {
            let taskID = backgroundTaskID
            backgroundTaskID = .invalid
            endBackgroundTask(taskID)
        }
        if isSuspended {
            isSuspended = false
            resume()
        }
    }

    private func finishExpiration(taskID: UIBackgroundTaskIdentifier) {
        backgroundTaskID = .invalid
        suspendIfNeeded()
        endBackgroundTask(taskID)
    }

    private func suspendIfNeeded() {
        guard !isSuspended else { return }
        isSuspended = true
        suspend()
    }
}
