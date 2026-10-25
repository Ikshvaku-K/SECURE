import Foundation
import SecureCore
import UserNotifications

public enum NotificationAction: Sendable, Equatable {
    case approve(requestID: String)
    case deny(requestID: String)
    case open(requestID: String?)
}

/// Local notifications only; nothing leaves the phone.
@MainActor
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

    public static let transferRequestCategory = "TRANSFER_REQUEST"
    public static let budgetAlertCategory = "BUDGET_ALERT"
    static let approveAction = "APPROVE"
    static let denyAction = "DENY"

    /// Called when the user taps a notification or one of its buttons. Actions that arrive before a handler
    /// is set (the app was launched by the tap) are delivered as soon as it is.
    public var onAction: ((NotificationAction) -> Void)? {
        didSet {
            guard let onAction else { return }
            let queued = pendingActions
            pendingActions.removeAll()
            queued.forEach(onAction)
        }
    }

    private var pendingActions: [NotificationAction] = []

    private var center: UNUserNotificationCenter { .current() }

    public func configure() {
        center.delegate = self
        // Approve opens the app: Face ID can't be shown from the background, and UWB ranging needs the app in front.
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve", options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.transferRequestCategory, actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.budgetAlertCategory, actions: [], intentIdentifiers: []),
        ])
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// "Clothing budget: $180.00 of $200.00 spent". Identified per budget, window and level, so each alert fires once per window.
    public func postBudgetAlert(categoryName: String, status: BudgetStatus) async {
        let level = status.isOver ? 100 : status.budget.alertPercent
        let content = UNMutableNotificationContent()
        content.title = status.isOver ? "\(categoryName) budget exceeded" : "\(categoryName) budget alert"
        content.body = "\(status.spentAfterMoney.formatted()) spent of \(status.budget.cap.formatted()) limit."
        content.categoryIdentifier = Self.budgetAlertCategory
        content.sound = .default
        let id = "budget-\(status.budget.id)-\(status.window.startMS)-\(level)"
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// An incoming payment request with Approve and Deny buttons, e.g.
    /// "Clothing Budget Alert: $180 spent of $200 limit. Approve $25 transaction?"
    public func postTransferRequest(requestID: String, title: String, body: String, delay: TimeInterval? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.transferRequestCategory
        content.sound = .default
        content.userInfo = ["requestID": requestID]
        content.interruptionLevel = .timeSensitive
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        try? await center.add(UNNotificationRequest(identifier: "request-\(requestID)", content: content, trigger: trigger))
    }

    // MARK: UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let requestID = response.notification.request.content.userInfo["requestID"] as? String
        let action: NotificationAction = switch response.actionIdentifier {
        case Self.approveAction: .approve(requestID: requestID ?? "")
        case Self.denyAction: .deny(requestID: requestID ?? "")
        default: .open(requestID: requestID)
        }
        await MainActor.run {
            if let onAction { onAction(action) } else { pendingActions.append(action) }
        }
    }
}
