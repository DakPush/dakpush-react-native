import Foundation
import UIKit
import UserNotifications

/// The bridge's state for the whole process, and the Objective-C face of the
/// DakPush iOS SDK (vendored in this module) for `RNDakPush.mm`.
///
/// It starts the SDK when the app finishes launching, from the `DakPush`
/// dictionary in Info.plist (the Expo plugin writes it), and listens to it
/// from then on. Events wait until JS listens to their type: taps, in-app
/// clicks, foreground messages and errors (20 of each), and the last device
/// id. Everything here runs on the main thread.
@objc(DakPushRN)
public final class DakPushRN: NSObject {
    static let opened = "DakPush.opened"
    static let foreground = "DakPush.foreground"
    static let error = "DakPush.error"
    static let deviceIdEvent = "DakPush.deviceId"
    static let inAppClick = "DakPush.inAppClick"
    @objc public static let events: [String] = [opened, foreground, error, deviceIdEvent, inAppClick]
    static let maxHeld = 20

    private static var config: Config?
    private static var attached = false
    private static var subscriptions: [DakSubscription] = []
    private static weak var emitterOwner: AnyObject?
    private static var emitter: ((String, Any) -> Void)?
    private static var listening = Set<String>()
    private static var held: [String: [Any]] = [:]
    private static var initial: [String: Any]?
    private static var openedSeen = false
    private static var blocks: [Int: DakInAppBlock] = [:]

    // MARK: - Start

    /// Info.plist → `DakPush` (a dictionary).
    struct Config {
        let appId: String
        let baseURL: String
        let options: DakOptions
        let installNotificationDelegate: Bool

        static func read(_ bundle: Bundle = .main) -> Config? {
            guard let d = bundle.object(forInfoDictionaryKey: "DakPush") as? [String: Any] else { return nil }
            let appId = (d["AppId"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let baseURL = (d["BaseURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !appId.isEmpty, !baseURL.isEmpty else {
                NSLog("DakPush: Info.plist DakPush needs AppId and BaseURL; the SDK stays off")
                return nil
            }
            var o = DakOptions()
            if let v = d["AppGroup"] as? String, !v.isEmpty { o.appGroup = v }
            if let v = d["ShareTimezoneOffset"] as? Bool { o.shareTimezoneOffset = v }
            let show = d["ShowInForeground"] as? Bool ?? false
            o.foregroundPresentation = show ? [.banner, .list, .sound, .badge] : []
            if let v = d["RegisterForRemoteNotifications"] as? Bool { o.registerForRemoteNotifications = v }
            if let v = d["DebugLogs"] as? Bool { o.debugLogs = v }
            if let v = d["InAppMessages"] as? Bool { o.inAppMessages = v }
            if let v = d["SessionTimeout"] as? NSNumber, v.doubleValue >= 0 { o.sessionTimeout = v.doubleValue }
            if let v = d["InAppUrlSchemes"] as? [String] {
                let schemes = Set(v.map { $0.lowercased() }.filter { !$0.isEmpty })
                if !schemes.isEmpty { o.inAppUrlSchemes = schemes }
            }
            return Config(
                appId: appId, baseURL: baseURL, options: o,
                installNotificationDelegate: d["InstallNotificationDelegate"] as? Bool ?? true)
        }
    }

    /// Whether Info.plist allows the app delegate proxy (`DakPush` →
    /// `AppDelegateProxy`, true by default).
    @objc public static var appDelegateProxyEnabled: Bool {
        let d = Bundle.main.object(forInfoDictionaryKey: "DakPush") as? [String: Any]
        return d?["AppDelegateProxy"] as? Bool ?? true
    }

    /// From `RNDakPushLaunch.m` when the app finished launching.
    @MainActor
    @objc public static func startFromInfoPlist() {
        guard let c = Config.read() else {
            if Bundle.main.object(forInfoDictionaryKey: "DakPush") == nil {
                NSLog("DakPush is not set up in Info.plist (DakPush → AppId, BaseURL); not starting")
            }
            return
        }
        Dak.initialize(appId: c.appId, baseURL: c.baseURL, options: c.options)
        guard Dak.isInitialized else { return }
        config = c
        if c.installNotificationDelegate { Dak.installNotificationDelegate() }
        attach()
    }

    /// Listens to the SDK once it runs. Also called when the module starts,
    /// for apps that call `Dak.initialize` themselves.
    @MainActor
    @objc public static func attach() {
        guard !attached, Dak.isInitialized else { return }
        attached = true
        subscriptions = [
            // The SDK calls its listeners on the main thread.
            Dak.addOpenedListener { n in tapped(n) },
            Dak.addForegroundListener { n in deliver(foreground, notificationMap(n)) },
            Dak.addErrorListener { e in deliver(error, errorMap(e)) },
            Dak.addDeviceIdListener { id in deliver(deviceIdEvent, id) },
            Dak.addInAppClickListener { c in deliver(inAppClick, clickMap(c)) },
        ]
    }

    // MARK: - Events

    /// The module now running JS sends the events; the one before it (a JS
    /// reload) no longer does.
    @MainActor
    @objc public static func setEmitter(_ owner: AnyObject, emit: @escaping (String, Any) -> Void) {
        emitterOwner = owner
        emitter = emit
        listening.removeAll()
    }

    @MainActor
    @objc public static func clearEmitter(_ owner: AnyObject) {
        guard emitterOwner === owner else { return }
        emitterOwner = nil
        emitter = nil
        listening.removeAll()
    }

    /// JS listens to [event] now: it gets what was kept for it.
    @MainActor
    @objc public static func jsListening(_ owner: AnyObject, event: String) {
        guard emitterOwner === owner, events.contains(event), let emit = emitter else { return }
        listening.insert(event)
        let kept = held.removeValue(forKey: event) ?? []
        for payload in kept { emit(event, payload) }
    }

    @MainActor
    private static func tapped(_ n: DakNotification) {
        let map = notificationMap(n)
        // The first tap of the process that came before JS listened to taps:
        // the one that opened the app.
        if !openedSeen && !listening.contains(opened) { initial = map }
        openedSeen = true
        deliver(opened, map)
    }

    @MainActor
    private static func deliver(_ event: String, _ payload: Any) {
        if let emit = emitter, listening.contains(event) {
            emit(event, payload)
            return
        }
        var q = held[event] ?? []
        if event == deviceIdEvent { q.removeAll() }
        q.append(payload)
        if q.count > maxHeld { q.removeFirst(q.count - maxHeld) }
        held[event] = q
    }

    // MARK: - State

    @MainActor
    @objc public static func state() -> [String: Any] {
        [
            "started": Dak.isInitialized,
            "appId": config?.appId ?? NSNull(),
            "baseUrl": config?.baseURL ?? NSNull(),
            "sdkVersion": "ios-\(Dak.version)",
            "platform": "ios",
        ]
    }

    @objc public static var isStarted: Bool { Dak.isInitialized }

    @objc public static var deviceId: String? { Dak.deviceId }

    @MainActor
    @objc public static var initialNotification: [String: Any]? { initial }

    // MARK: - Permission

    @MainActor
    @objc public static func requestPermission(provisional: Bool, completion: @escaping (Bool) -> Void) {
        Dak.requestPermission(provisional: provisional) { completion($0) }
    }

    @MainActor
    @objc public static func hasPermission(completion: @escaping (Bool) -> Void) {
        Dak.hasPermission { completion($0) }
    }

    @MainActor
    @objc public static func openNotificationSettings() {
        Dak.openNotificationSettings()
    }

    // MARK: - User, tags, subscription

    /// [completion] gets nil, or `{ code, message, field, status }`.
    @MainActor
    @objc public static func login(
        _ externalId: String, authHash: String?, completion: @escaping ([String: Any]?) -> Void
    ) {
        Dak.login(externalId, authHash: authHash) { completion($0.map(errorMap)) }
    }

    @MainActor
    @objc public static func logout(completion: @escaping ([String: Any]?) -> Void) {
        Dak.logout { completion($0.map(errorMap)) }
    }

    /// Values are strings, or NSNull for a removal.
    @MainActor
    @objc public static func setTags(_ tags: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        var values: [String: Any?] = [:]
        for (k, v) in tags {
            // updateValue keeps a nil (a removal); subscript assignment would drop the key.
            let value: Any? = v is NSNull ? nil : v
            values.updateValue(value, forKey: k)
        }
        Dak.setTags(values) { completion($0.map(errorMap)) }
    }

    @MainActor
    @objc public static func setSubscribed(_ subscribed: Bool, completion: @escaping ([String: Any]?) -> Void) {
        Dak.setSubscribed(subscribed) { completion($0.map(errorMap)) }
    }

    @objc public static func setBadge(_ count: Int) {
        Dak.setBadge(count)
    }

    @MainActor
    @objc public static func flush(completion: @escaping ([String: Any]?) -> Void) {
        Dak.flush { completion($0.map(errorMap)) }
    }

    // MARK: - In-app messages

    /// Values are NSString or NSNumber (booleans are CFBoolean).
    @objc public static func addTriggers(_ triggers: [String: Any]) {
        var values: [String: DakTriggerValue] = [:]
        for (k, v) in triggers {
            if let s = v as? String {
                values[k] = s
            } else if let n = v as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    values[k] = n.boolValue
                } else {
                    let d = n.doubleValue
                    if d == d.rounded(), abs(d) < 1e15 { values[k] = Int(d) } else { values[k] = d }
                }
            }
        }
        if !values.isEmpty { Dak.addTriggers(values) }
    }

    @objc public static func removeTriggers(_ keys: [String]) {
        Dak.removeTriggers(keys)
    }

    @objc public static func clearTriggers() {
        Dak.clearTriggers()
    }

    @objc public static func pauseInApp(_ paused: Bool) {
        Dak.pauseInApp(paused)
    }

    @objc public static var isInAppPaused: Bool { Dak.isInAppPaused }

    @MainActor
    @objc public static func blockInApp(_ id: Int) {
        blocks.removeValue(forKey: id)?.end()
        blocks[id] = Dak.blockInApp()
    }

    @MainActor
    @objc public static func endInAppBlock(_ id: Int) {
        blocks.removeValue(forKey: id)?.end()
    }

    /// Ends every block, when JS reloads.
    @MainActor
    @objc public static func endAllInAppBlocks() {
        let all = blocks.values
        blocks.removeAll()
        all.forEach { $0.end() }
    }

    @MainActor
    @objc public static func refreshInApp(completion: @escaping () -> Void) {
        guard Dak.isInitialized else {
            completion()
            return
        }
        Dak.refreshInApp { completion() }
    }

    // MARK: - From the app delegate (RNDakPushLaunch.m)

    @objc public static func didRegister(deviceToken: Data) {
        Dak.setDeviceToken(deviceToken)
    }

    @objc public static func didFailToRegister(error: Error) {
        Dak.failedToRegister(with: error)
    }

    /// False for pushes not sent through DakPush; [completion] is not called then.
    @objc public static func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any], completion: @escaping (UIBackgroundFetchResult) -> Void
    ) -> Bool {
        Dak.didReceiveRemoteNotification(userInfo, completion: completion)
    }

    // MARK: - Maps for JS

    static func notificationMap(_ n: DakNotification) -> [String: Any] {
        [
            "id": n.id ?? NSNull(),
            "title": n.title ?? NSNull(),
            "body": n.body ?? NSNull(),
            "url": n.url ?? NSNull(),
            "imageUrl": n.imageURL ?? NSNull(),
            "data": n.data,
            "buttons": n.buttons.map { ["id": $0.id, "text": $0.text, "url": $0.url ?? NSNull()] as [String: Any] },
            "actionId": n.actionId ?? NSNull(),
            "raw": n.raw,
        ]
    }

    static func clickMap(_ c: DakInAppClick) -> [String: Any] {
        [
            "messageId": c.messageId,
            "buttonId": c.buttonId ?? NSNull(),
            "actionType": c.actionType.rawValue,
            "url": c.url ?? NSNull(),
            "tags": c.tags,
        ]
    }

    static func errorMap(_ e: DakError) -> [String: Any] {
        [
            "message": e.message,
            "code": e.code,
            "field": e.field ?? NSNull(),
            "status": e.status ?? NSNull(),
        ]
    }
}
