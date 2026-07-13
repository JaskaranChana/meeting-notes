import Foundation
import UserNotifications

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
