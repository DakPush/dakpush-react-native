import UserNotifications

/// Settings for ``Dak/initialize(appId:baseURL:options:)``. All of them have
/// defaults.
///
/// ```swift
/// DakOptions(appGroup: "group.com.example.app.dakpush", shareTimezoneOffset: true)
/// ```
public struct DakOptions: Sendable {
    /// The App Group the app shares with its notification service extension
    /// (DakPushExtension), so the extension can report deliveries and badge
    /// increments. Without it, pushes count as delivered only when the app
    /// sees them (open, or tapped).
    public var appGroup: String?

    /// Send the phone's UTC offset in minutes (only the offset, like +360),
    /// so pushes can go at the user's local time and respect quiet hours. Off
    /// by default; then the app's timezone is used.
    public var shareTimezoneOffset: Bool

    /// How a DakPush notification shows while the app is open, unless
    /// ``Dak/setForegroundPresentation(_:)`` decides per message. `[]` shows
    /// nothing (the foreground listeners still get it).
    public var foregroundPresentation: UNNotificationPresentationOptions

    /// Call `UIApplication.registerForRemoteNotifications()` at every start,
    /// as Apple recommends, to get the APNs token. It never shows a prompt.
    public var registerForRemoteNotifications: Bool

    /// Log what the SDK does (Console.app, subsystem "dakpush").
    public var debugLogs: Bool

    /// Show in-app messages. With false the SDK never fetches or shows them.
    public var inAppMessages: Bool

    /// Back from the background after this long starts a new session, for
    /// in-app triggers (session count, time in the session) and frequency
    /// ("every session"). A cold start always does. 5 minutes by default.
    public var sessionTimeout: TimeInterval

    /// The schemes an in-app message's `url` action opens; others are not
    /// opened (the click listener still gets the click). Add `mailto` or
    /// `tel` if your messages use them.
    public var inAppUrlSchemes: Set<String>

    public init(
        appGroup: String? = nil,
        shareTimezoneOffset: Bool = false,
        foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound, .badge],
        registerForRemoteNotifications: Bool = true,
        debugLogs: Bool = false,
        inAppMessages: Bool = true,
        sessionTimeout: TimeInterval = 300,
        inAppUrlSchemes: Set<String> = ["https", "http"]
    ) {
        self.appGroup = appGroup
        self.shareTimezoneOffset = shareTimezoneOffset
        self.foregroundPresentation = foregroundPresentation
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.debugLogs = debugLogs
        self.inAppMessages = inAppMessages
        self.sessionTimeout = sessionTimeout
        self.inAppUrlSchemes = inAppUrlSchemes
    }
}
