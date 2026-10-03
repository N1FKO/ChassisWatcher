import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error = error {
                        Log.error("Notification authorization request failed: \(error)")
                    } else {
                        Log.info("Notification authorization granted: \(granted)")
                    }
                }
            } else {
                Log.info("Notification authorization status: \(settings.authorizationStatus.rawValue)")
            }
        }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.error("Failed to deliver notification '\(title)': \(error)")
            }
        }
    }
}
