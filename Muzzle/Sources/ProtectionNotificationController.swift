import Foundation
import OSLog
import UserNotifications

@MainActor
protocol ProtectionNotifying {
    func notifySpeakersBlocked(reason: ProtectionReason)
}

@MainActor
final class ProtectionNotificationController: ProtectionNotifying {
    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "Muzzle", category: "ProtectionNotifications")
    private var authorizationRequested = false
    private var lastNotification: (reason: ProtectionReason, sentAt: Date)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notifySpeakersBlocked(reason: ProtectionReason) {
        guard shouldSendNotification(reason: reason) else {
            return
        }

        Task {
            do {
                guard try await ensureAuthorization() else {
                    logger.debug("Protection notification skipped because authorization is unavailable")
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = "Speakers muted"
                content.body = Self.notificationBody(reason: reason)
                content.sound = nil

                let request = UNNotificationRequest(
                    identifier: "protection-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
                logger.info("Protection notification delivered: reason=\(reason.rawValue, privacy: .public)")
            } catch {
                logger.error("Failed to send protection notification: \(error.localizedDescription)")
            }
        }
    }

    private func shouldSendNotification(reason: ProtectionReason) -> Bool {
        let now = Date()
        defer {
            lastNotification = (reason: reason, sentAt: now)
        }

        guard let lastNotification else {
            return true
        }

        let isDuplicate =
            lastNotification.reason == reason &&
            now.timeIntervalSince(lastNotification.sentAt) < 2

        return !isDuplicate
    }

    private func ensureAuthorization() async throws -> Bool {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !authorizationRequested else {
                return false
            }

            authorizationRequested = true
            return try await center.requestAuthorization(options: [.alert])
        @unknown default:
            return false
        }
    }

    nonisolated static func notificationBody(reason: ProtectionReason) -> String {
        switch reason {
        case .outputChanged:
            return "Built-in speakers were muted because your headphones disconnected."
        case .wake:
            return "Built-in speakers were muted after your Mac woke up."
        case .networkChanged:
            return "Built-in speakers were muted after a network change."
        case .manual:
            return "Built-in speakers were muted because protection resumed."
        }
    }
}
