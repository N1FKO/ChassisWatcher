import Foundation

/// Tracks which alert conditions are currently active so we can:
///  - fire once when a condition starts (not every single poll)
///  - re-fire periodically while it stays active (repeatAlertIntervalSeconds)
///  - fire a "recovered" notice when it clears
final class AlertManager {
    private struct AlertState {
        var isActive: Bool = false
        var lastSentAt: Date?
    }

    private var states: [String: AlertState] = [:]
    private let repeatInterval: TimeInterval

    init(repeatAlertIntervalSeconds: TimeInterval) {
        self.repeatInterval = repeatAlertIntervalSeconds
    }

    /// Call once per poll per condition. `isOutOfRange` reflects the current
    /// reading; `title`/`body` describe the alert to send if we decide to notify.
    func evaluate(
        key: String,
        isOutOfRange: Bool,
        title: String,
        body: String,
        recoveredBody: String,
        sendEmail: Bool,
        smtpConfig: SMTPConfig
    ) {
        var state = states[key] ?? AlertState()
        let now = Date()

        if isOutOfRange {
            let shouldSend: Bool
            if !state.isActive {
                shouldSend = true // just became a problem
            } else if let last = state.lastSentAt, now.timeIntervalSince(last) >= repeatInterval {
                shouldSend = true // still a problem, time to remind again
            } else {
                shouldSend = false
            }

            if shouldSend {
                Log.warn("ALERT [\(key)]: \(title) - \(body)")
                Notifier.send(title: title, body: body)
                if sendEmail {
                    sendEmailSafely(subject: "[ChassisWatcher] \(title)", body: body, config: smtpConfig)
                }
                state.lastSentAt = now
            }
            state.isActive = true
        } else {
            if state.isActive {
                Log.info("RECOVERED [\(key)]: \(recoveredBody)")
                Notifier.send(title: "ChassisWatcher: recovered", body: recoveredBody)
                if sendEmail {
                    sendEmailSafely(subject: "[ChassisWatcher] Recovered: \(key)", body: recoveredBody, config: smtpConfig)
                }
            }
            state.isActive = false
            state.lastSentAt = nil
        }

        states[key] = state
    }

    private func sendEmailSafely(subject: String, body: String, config: SMTPConfig) {
        do {
            try SMTPMailer.send(subject: subject, body: body, config: config)
        } catch {
            Log.error("Failed to send alert email: \(error)")
        }
    }
}
