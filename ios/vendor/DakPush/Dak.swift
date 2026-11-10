import Foundation
import UIKit
import UserNotifications

/// The SDK's entry point.
///
/// ```swift
/// final class AppDelegate: NSObject, UIApplicationDelegate {
///     func application(
///         _ application: UIApplication,
///         didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
///     ) -> Bool {
///         Dak.initialize(appId: "APP_ID", baseURL: "https://push.example.com")
///         Dak.installNotificationDelegate()
///         Dak.addOpenedListener { n in route(n.url) }
///         return true
///     }
///
///     func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
///         Dak.setDeviceToken(token)
///     }
/// }
/// ```
public enum Dak {
    /// The SDK's version. The server sees it as `ios-` and this.
    public static let version = DakPushInfo.version

    static let runtime = DakRuntime()
    static let tagKey = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.:-]{1,64}$")

    /// Starts the SDK. Call it in `application(_:didFinishLaunchingWithOptions:)`,
    /// so the tap that started the app is seen. Later calls do nothing.
    ///
    /// It returns at once: reading the saved state and registering the device
    /// run in the background, so a slow network never holds the app's start.
    /// Calls like ``login(_:authHash:completion:)`` made meanwhile wait for the
    /// saved state, then sync.
    ///
    /// - Parameters:
    ///   - appId: the App ID from the DakPush dashboard.
    ///   - baseURL: the server's public URL, without `/v1`. It must be https;
    ///     plain http works only for `localhost` and `127.0.0.1` (the simulator).
    ///
    /// An appId or baseURL that cannot be right stops debug builds
    /// (`assertionFailure`); release builds log it and stay off.
    public static func initialize(appId: String, baseURL: String, options: DakOptions = DakOptions()) {
        let log = DakLog(debug: options.debugLogs)
        guard let base = DakApi.checkBaseURL(baseURL) else {
            log.w("DakPush: baseURL must be an https URL like https://push.example.com, not \(baseURL)")
            assertionFailure("DakPush: baseURL must be an https URL like https://push.example.com, not \(baseURL)")
            return
        }
        guard DakApi.checkAppId(appId) else {
            log.w("DakPush: appId must be the App ID from the DakPush dashboard, not \(appId)")
            assertionFailure("DakPush: appId must be the App ID from the DakPush dashboard, not \(appId)")
            return
        }
        if runtime.client != nil {
            log.w("DakPush: Dak.initialize was called again; the first call's settings stay")
            return
        }
        var group: DakAppGroup?
        if let id = options.appGroup {
            group = DakAppGroup(identifier: id)
            if group == nil {
                log.w(
                    "DakPush: App Group \(id) is not set up for the app: add it under Signing & Capabilities → App Groups for the app and its notification service extension"
                )
            }
        }
        let api = DakApi(baseURL: base, appId: appId, http: URLSessionHTTP(), userAgent: DakPushInfo.userAgent)
        let client = DakClient(
            api: api, store: FileStateStore.standard(), secrets: KeychainSecretStore(),
            platform: IOSPlatformInfo(protectedData: runtime.protectedData), scheduler: QueueScheduler(),
            callbacks: { DispatchQueue.main.async(execute: $0) }, events: runtime, log: log,
            sdkVersion: "ios-\(version)", shareTimezoneOffset: options.shareTimezoneOffset, appGroup: group,
            categories: group == nil ? nil : DakSystemCategoryCenter())
        onMain {
            runtime.protectedData.value = UIApplication.shared.isProtectedDataAvailable
            guard runtime.install(client, options: options, log: log, appGroup: group) else { return }
            if options.inAppMessages { startInApp(api: api, client: client, options: options, log: log) }
            observeApp(client)
            if options.registerForRemoteNotifications {
                runtime.tokenState.update { if case .none = $0 { $0 = .asked(Date()) } }
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// True once ``initialize(appId:baseURL:options:)`` ran.
    public static var isInitialized: Bool { runtime.client != nil }

    /// This device's id on the DakPush server, or nil before it is
    /// registered. Use ``addDeviceIdListener(_:)`` to get it when it comes.
    public static var deviceId: String? { runtime.client?.currentDeviceId }

    /// Calls [listener] with the device id: at once when there is one, then
    /// each new one (the first registration, or registering again after the
    /// server forgot the device). Never the same id twice in a row.
    @discardableResult
    public static func addDeviceIdListener(_ listener: @escaping DakDeviceIdListener) -> DakSubscription {
        runtime.deviceIds.add(listener)
    }

    // MARK: - APNs token

    /// Pass the APNs token on from your app delegate's
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func setDeviceToken(_ deviceToken: Data) {
        runtime.token(hex(deviceToken))
    }

    /// Pass failures on from your app delegate's
    /// `application(_:didFailToRegisterForRemoteNotificationsWithError:)`, so
    /// they are logged. (The simulator fails without a team that has Push
    /// Notifications for the bundle id.)
    public static func failedToRegister(with error: Error) {
        runtime.tokenState.value = .failed
        runtime.log.w("DakPush: no APNs token: \(error.localizedDescription)")
    }

    // MARK: - User, tags, subscription

    /// Links this device to your user id. With identity verification on (the
    /// server's default), [authHash] must come from your server:
    /// hex(HMAC-SHA256(key = identity secret, message = externalId)).
    ///
    /// [completion] gets a ``DakError`` when the server refuses (a wrong auth
    /// hash); then only the user id is rolled back. Network problems never
    /// fail: the change is saved and sent later. An id that is empty, over 128
    /// bytes of UTF-8 or an email address fails with code `invalid`.
    public static func login(
        _ externalId: String, authHash: String? = nil, completion: (@MainActor (DakError?) -> Void)? = nil
    ) {
        guard !externalId.isEmpty, utf8Length(externalId) <= 128, !externalId.contains("@") else {
            return fail(completion, .invalid("use your own user id (1-128 bytes, not an email address)", field: "external_id"))
        }
        guard let client = client(completion) else { return }
        client.login(externalId, authHash: authHash.flatMap { $0.isEmpty ? nil : $0 }, callback: callback(completion))
    }

    /// See ``login(_:authHash:completion:)``; throws the ``DakError``.
    public static func login(_ externalId: String, authHash: String? = nil) async throws {
        try await awaiting { login(externalId, authHash: authHash, completion: $0) }
    }

    /// Unlinks the user from this device and removes its tags, so the next
    /// user of the phone starts without them. Push permission and the
    /// subscription stay.
    public static func logout(completion: (@MainActor (DakError?) -> Void)? = nil) {
        guard let client = client(completion) else { return }
        client.logout(callback: callback(completion))
    }

    /// See ``logout(completion:)``.
    public static func logout() async throws {
        try await awaiting { logout(completion: $0) }
    }

    /// Sets tags on this device; a nil or empty value removes the tag. Values
    /// are strings, numbers or booleans, sent as strings. A bad key (1-64 of
    /// `A-Z a-z 0-9 _ . : -`), a value of another type or over 255 bytes of
    /// UTF-8, and more than 50 tags fail with code `invalid`.
    public static func setTags(_ tags: [String: Any?], completion: (@MainActor (DakError?) -> Void)? = nil) {
        var values: [String: String?] = [:]
        for (k, v) in tags {
            guard tagKey.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil else {
                return fail(completion, .invalid("tag key \(k) must be 1-64 of A-Z a-z 0-9 _ . : -", field: "tags"))
            }
            guard let s = tagValue(v) else {
                return fail(completion, .invalid("tag \(k): values must be strings, numbers or booleans", field: "tags"))
            }
            if let text = s, utf8Length(text) > 255 {
                return fail(completion, .invalid("tag \(k): at most 255 bytes of UTF-8", field: "tags"))
            }
            values[k] = s
        }
        guard let client = client(completion) else { return }
        client.setTags(values, callback: callback(completion))
    }

    /// See ``setTags(_:completion:)``.
    public static func setTags(_ tags: [String: Any?]) async throws {
        try await awaiting { setTags(tags, completion: $0) }
    }

    /// Sets one tag; see ``setTags(_:completion:)``.
    public static func setTag(_ key: String, _ value: Any?, completion: (@MainActor (DakError?) -> Void)? = nil) {
        setTags([key: value], completion: completion)
    }

    /// Removes the tags with these keys.
    public static func deleteTags(_ keys: [String], completion: (@MainActor (DakError?) -> Void)? = nil) {
        setTags(Dictionary(keys.map { ($0, nil as Any?) }, uniquingKeysWith: { a, _ in a }), completion: completion)
    }

    /// Removes one tag.
    public static func deleteTag(_ key: String, completion: (@MainActor (DakError?) -> Void)? = nil) {
        deleteTags([key], completion: completion)
    }

    /// Opts this device out of (false) or back into (true) all pushes, for a
    /// switch in your app's settings. Notification permission is not changed.
    public static func setSubscribed(_ subscribed: Bool, completion: (@MainActor (DakError?) -> Void)? = nil) {
        guard let client = client(completion) else { return }
        client.setSubscribed(subscribed, callback: callback(completion))
    }

    /// See ``setSubscribed(_:completion:)``.
    public static func setSubscribed(_ subscribed: Bool) async throws {
        try await awaiting { setSubscribed(subscribed, completion: $0) }
    }

    /// Sends anything waiting now, for example when the network comes back.
    public static func flush(completion: (@MainActor (DakError?) -> Void)? = nil) {
        guard let client = client(completion) else { return }
        client.flush(callback: callback(completion))
    }

    // MARK: - Permission

    /// Asks the user to allow notifications (alert, sound, badge). With
    /// [provisional], iOS asks nothing: notifications go quietly to the
    /// Notification Center, where the user keeps or turns them off.
    /// [completion] gets whether notifications are allowed. After a refusal
    /// iOS never asks again; ``openNotificationSettings()`` is left then.
    public static func requestPermission(
        provisional: Bool = false, completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if provisional { options.insert(.provisional) }
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            if let error { runtime.log.d("DakPush: permission request failed: \(error)") }
            runtime.client?.refreshPermission()
            if let completion { DispatchQueue.main.async { completion(granted) } }
        }
    }

    /// See ``requestPermission(provisional:completion:)``.
    public static func requestPermission(provisional: Bool = false) async -> Bool {
        await withCheckedContinuation { c in requestPermission(provisional: provisional) { c.resume(returning: $0) } }
    }

    /// Whether the user allows this app's notifications (provisional ones count).
    public static func hasPermission(completion: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = IOSPlatformInfo.allows(settings.authorizationStatus)
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    /// See ``hasPermission(completion:)``.
    public static func hasPermission() async -> Bool {
        await withCheckedContinuation { c in hasPermission { c.resume(returning: $0) } }
    }

    /// Opens this app's notification settings.
    @MainActor
    public static func openNotificationSettings() {
        let name: String
        if #available(iOS 16.0, *) {
            name = UIApplication.openNotificationSettingsURLString
        } else {
            name = UIApplication.openSettingsURLString
        }
        if let url = URL(string: name) { UIApplication.shared.open(url) }
    }

    // MARK: - Notifications

    /// Calls [listener] for taps on DakPush notifications, on the main thread.
    /// ``DakNotification/actionId`` tells which button was tapped, if one was.
    /// Taps that come before the first listener (the tap that started the app)
    /// are kept for it. The SDK reports the open itself.
    @discardableResult
    public static func addOpenedListener(_ listener: @escaping DakOpenedListener) -> DakSubscription {
        runtime.opened.add(listener)
    }

    /// Calls [listener] for DakPush messages that arrive while the app is
    /// open, silent ones too (those through
    /// ``didReceiveRemoteNotification(_:completion:)``).
    @discardableResult
    public static func addForegroundListener(_ listener: @escaping DakForegroundListener) -> DakSubscription {
        runtime.foreground.add(listener)
    }

    /// Calls [listener] for changes the server refused, such as a wrong auth
    /// hash or a bad tag, also from syncs that run in the background. Only the
    /// refused field is rolled back; the rest (an opt-out above all) is still
    /// sent.
    @discardableResult
    public static func addErrorListener(_ listener: @escaping DakErrorListener) -> DakSubscription {
        runtime.errors.add(listener)
    }

    /// Decides per message how a DakPush notification shows while the app is
    /// open (`[]` for not at all). Called on the thread iOS asks on. Without
    /// it, ``DakOptions/foregroundPresentation`` applies; nil goes back to it.
    public static func setForegroundPresentation(
        _ choose: (@Sendable (DakNotification) -> UNNotificationPresentationOptions)?
    ) {
        runtime.foregroundChooser.value = choose
    }

    /// Makes the SDK the notification center's delegate, forwarding
    /// everything to the delegate that was set before (and, for other
    /// notifications than DakPush's, only to it). Call it in
    /// `application(_:didFinishLaunchingWithOptions:)`, after setting a
    /// delegate of your own if you have one. Or keep your own delegate and
    /// call ``handle(_:)`` and ``presentationOptions(for:)`` from it.
    @MainActor
    public static func installNotificationDelegate() {
        let center = UNUserNotificationCenter.current()
        if let current = center.delegate as? DakNotificationCenterDelegate, current === runtime.delegateProxy { return }
        let proxy = DakNotificationCenterDelegate(forwardingTo: center.delegate)
        runtime.delegateProxy = proxy
        center.delegate = proxy
    }

    /// For your own `userNotificationCenter(_:didReceive:withCompletionHandler:)`:
    /// reports the tap and calls the opened listeners. True for DakPush
    /// notifications (the response is handled once, however often it is
    /// passed); you still call the completion handler.
    @discardableResult
    public static func handle(_ response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        guard DakNotification.isDak(content.userInfo) else { return false }
        let action = response.actionIdentifier
        if action == UNNotificationDismissActionIdentifier { return true }
        let actionId = action == UNNotificationDefaultActionIdentifier ? nil : action
        runtime.tap(DakNotification(content: content, actionId: actionId))
        return true
    }

    /// For your own `userNotificationCenter(_:willPresent:withCompletionHandler:)`:
    /// for a DakPush notification, records its delivery, calls the foreground
    /// listeners, and returns how to show it; nil for other notifications.
    public static func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        let content = notification.request.content
        guard DakNotification.isDak(content.userInfo) else { return nil }
        let n = DakNotification(content: content)
        runtime.arrived(n, listeners: true)
        return runtime.presentation(for: n)
    }

    /// For silent pushes: call it from your app delegate's
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    /// It records the delivery and, while the app is open, calls the
    /// foreground listeners. [completion] runs once the receipt is sent or
    /// kept, within 20 seconds. False for pushes not sent through DakPush;
    /// [completion] is not called then.
    @discardableResult
    public static func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any], completion: ((UIBackgroundFetchResult) -> Void)? = nil
    ) -> Bool {
        guard DakNotification.isDak(userInfo) else { return false }
        let n = DakNotification(userInfo: userInfo)
        let once = Locked(completion)
        let finish: @Sendable () -> Void = {
            let f = once.update { c -> ((UIBackgroundFetchResult) -> Void)? in
                let g = c
                c = nil
                return g
            }
            f?(.noData)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: finish)
        onMain {
            let active = UIApplication.shared.applicationState == .active
            runtime.arrived(n, listeners: active && n.isSilent) { _ in finish() }
        }
        return true
    }

    /// Sets the app icon's badge; later badge increments from pushes add to
    /// it (through the notification service extension).
    public static func setBadge(_ count: Int) {
        let value = max(0, count)
        runtime.appGroup?.badge = value
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(value, withCompletionHandler: nil)
        } else {
            onMain { UIApplication.shared.applicationIconBadgeNumber = value }
        }
    }

    // MARK: - Helpers

    private static func client(_ completion: (@MainActor (DakError?) -> Void)?) -> DakClient? {
        if let c = runtime.client { return c }
        runtime.log.w("DakPush: call Dak.initialize first")
        fail(completion, .notInitialized)
        return nil
    }

    private static func fail(_ completion: (@MainActor (DakError?) -> Void)?, _ error: DakError) {
        runtime.log.w("DakPush: \(error.message)")
        if let completion { DispatchQueue.main.async { completion(error) } }
    }

    /// The client's callbacks already run on the main queue.
    private static func callback(_ completion: (@MainActor (DakError?) -> Void)?) -> DakCallback? {
        guard let completion else { return nil }
        return { error in MainActor.assumeIsolated { completion(error) } }
    }

    private static func awaiting(_ start: (@escaping @MainActor (DakError?) -> Void) -> Void) async throws {
        let error: DakError? = await withCheckedContinuation { c in start { c.resume(returning: $0) } }
        if let error { throw error }
    }

    /// A tag value as the server stores it; nil inside for a removal, nil
    /// outside for a type it cannot take.
    static func tagValue(_ value: Any?) -> String?? {
        guard let value else { return .some(nil) }
        switch value {
        case Optional<Any>.none: return .some(nil)
        case let s as String: return s.isEmpty ? .some(nil) : s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let i as any BinaryInteger: return "\(i)"
        case let d as Double: return "\(d)"
        case let f as Float: return "\(f)"
        default: return nil
        }
    }

    /// Lifecycle: resume, background, unlock, and setup checks in debug builds.
    @MainActor
    private static func observeApp(_ client: DakClient) {
        let center = NotificationCenter.default
        runtime.observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                client.onResume()
                MainActor.assumeIsolated {
                    inApp.controller?.lifecycle(foreground: true)
                    #if DEBUG
                        checkSetup()
                    #endif
                }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { inAppToBackground() }
            },
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) {
                _ in
                runtime.protectedData.value = true
                client.retryLoad()
                MainActor.assumeIsolated { inApp.controller?.retryLoad() }
            },
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) {
                _ in
                runtime.protectedData.value = false
            },
        ]
    }

    /// The app went to the background: in-app events still waiting are sent,
    /// with the few seconds iOS gives for it.
    @MainActor
    private static func inAppToBackground() {
        guard let controller = inApp.controller else { return }
        let app = UIApplication.shared
        let task = Locked(UIBackgroundTaskIdentifier.invalid)
        let end: @Sendable () -> Void = {
            let id = task.update { t -> UIBackgroundTaskIdentifier in
                let id = t
                t = .invalid
                return id
            }
            // Both callers run on the main thread: ended before they return.
            if id != .invalid { onMain { UIApplication.shared.endBackgroundTask(id) } }
        }
        task.value = app.beginBackgroundTask(withName: "DakPush in-app events", expirationHandler: end)
        controller.lifecycle(foreground: false)
        controller.flushEvents(completion: end)
    }

    /// Debug builds: setup mistakes that would make taps or tokens go unseen.
    @MainActor
    static func checkSetup() {
        let delegate = UNUserNotificationCenter.current().delegate
        if delegate == nil {
            runtime.warnOnce(
                "delegate",
                "DakPush: no notification center delegate, so taps are not seen. Call Dak.installNotificationDelegate() in application(_:didFinishLaunchingWithOptions:), or pass responses to Dak.handle(_:) from your own delegate."
            )
        } else if let proxy = runtime.delegateProxy, delegate !== proxy {
            runtime.warnOnce(
                "replaced",
                "DakPush: something replaced the delegate Dak.installNotificationDelegate() set. Call it after setting your own delegate."
            )
        }
        if case .asked(let at) = runtime.tokenState.value, Date().timeIntervalSince(at) > 15 {
            runtime.warnOnce(
                "token",
                "DakPush: no APNs token yet. Pass it on from application(_:didRegisterForRemoteNotificationsWithDeviceToken:) with Dak.setDeviceToken(_:), and failures with Dak.failedToRegister(with:)."
            )
        }
    }
}
