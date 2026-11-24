import MachO
import os
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications
import DayDoCore

/// Schedules local notifications for the next reminders (iOS keeps at most
/// 64 pending requests per app, so only the nearest ones are registered).
actor ReminderScheduler {
    private var isRescheduling = false
    private var dirty = false

    func reschedule(api: any DayDoAPI) async {
        // Mac Debug shares bundle id & UNUserNotificationCenter with the Release app.
        if DayDoApp.isMacDebug { return }
        if isRescheduling {
            dirty = true
            return
        }
        isRescheduling = true
        defer { isRescheduling = false }
        repeat {
            dirty = false
            await performReschedule(api: api)
        } while dirty
    }

    private func performReschedule(api: any DayDoAPI) async {
        let center = UNUserNotificationCenter.current()
        guard let upcoming = try? await api.upcomingReminders(limit: 60) else { return }
        let settings = await center.notificationSettings()
        let allowed: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .notDetermined:
            guard !upcoming.isEmpty else { return }
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            allowed = false
        @unknown default:
            allowed = false
        }
        guard allowed else { return }
        center.removeAllPendingNotificationRequests()
        for r in upcoming {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.userInfo = ["taskId": r.taskId]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireDate)
            let req = UNNotificationRequest(identifier: r.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }
}

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["taskId"] as? String else { return }
        await MainActor.run {
            model?.openDetailFromNotification(id)
        }
    }
}
