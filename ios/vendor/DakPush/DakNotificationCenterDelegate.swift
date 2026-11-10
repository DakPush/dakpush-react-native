import Foundation
import UserNotifications

/// The notification center delegate ``Dak/installNotificationDelegate()``
/// sets. It handles DakPush's notifications and forwards every call to the
/// delegate that was set before it:
///
/// - a tap: reported, the opened listeners called, then forwarded (that
///   delegate calls the completion handler, or this one does when it has
///   none);
/// - a DakPush notification while the app is open: shown as
///   ``DakOptions/foregroundPresentation`` or
///   ``Dak/setForegroundPresentation(_:)`` say; other notifications are left
///   to the earlier delegate (not shown without one, as iOS does);
/// - the in-app notification settings link: forwarded.
public final class DakNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// The delegate set before this one; held weakly, as the notification
    /// center holds its delegate.
    public private(set) weak var next: UNUserNotificationCenterDelegate?

    init(forwardingTo next: UNUserNotificationCenterDelegate?) {
        self.next = next
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if let options = Dak.presentationOptions(for: notification) {
            completionHandler(options)
            return
        }
        if next?.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            == nil
        {
            completionHandler([])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Dak.handle(response)
        if next?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) == nil {
            completionHandler()
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?)
    {
        next?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}
