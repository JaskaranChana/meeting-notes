import Foundation
import UserNotifications

enum ScribeflowNotificationPermission: Sendable, Equatable {
    case notDetermined
    case enabled
    case quiet
    case denied

    var canSchedule: Bool {
        self == .enabled || self == .quiet
    }

    var title: String {
        switch self {
        case .notDetermined: "Not enabled"
        case .enabled: "On"
        case .quiet: "Delivered quietly"
        case .denied: "Off"
        }
    }

    var detail: String {
        switch self {
        case .notDetermined: "Get alerts when captures finish and actions are due"
        case .enabled: "Ready alerts and action reminders are enabled"
        case .quiet: "Notifications arrive in Notification Center without normal alerts"
        case .denied: "Enable alerts in iPhone Settings"
        }
    }
}

actor ScribeflowNotificationAuthorization {
    static let shared = ScribeflowNotificationAuthorization()

    private var requestTask: Task<ScribeflowNotificationPermission, Never>?

    func currentPermission() async -> ScribeflowNotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.permission(from: settings)
    }

    func requestIfNeeded() async -> ScribeflowNotificationPermission {
        if let requestTask { return await requestTask.value }

        let task = Task { () -> ScribeflowNotificationPermission in
            let center = UNUserNotificationCenter.current()
            let current = await center.notificationSettings()
            let permission = Self.permission(from: current)
            guard permission == .notDetermined else { return permission }

            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return .notDetermined
            }
            return Self.permission(from: await center.notificationSettings())
        }
        requestTask = task
        let result = await task.value
        requestTask = nil
        return result
    }

    private static func permission(
        from settings: UNNotificationSettings
    ) -> ScribeflowNotificationPermission {
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return settings.alertSetting == .enabled ? .enabled : .quiet
        @unknown default:
            return .denied
        }
    }
}

enum ScribeflowNotificationTester {
    static func send() async -> Bool {
        let permission = await ScribeflowNotificationAuthorization.shared.requestIfNeeded()
        guard permission.canSchedule else { return false }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Scribeflow notifications are working"
        content.body = "Ready alerts and action reminders can appear on this device."
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 1
        content.threadIdentifier = "scribeflow.test"

        let identifier = "scribeflow.notification.test"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let meetingIDString = userInfo["meetingID"] as? String,
              let meetingID = UUID(uuidString: meetingIDString)
        else { return }

        await MainActor.run {
            PendingCaptureInbox.shared.requestOpenMeeting(meetingID)
        }
    }
}
