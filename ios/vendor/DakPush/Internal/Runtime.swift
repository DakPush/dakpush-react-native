import Foundation
import UIKit
import UserNotifications

/// What ``Dak`` keeps: the client once it exists, the listeners, and what
/// came before ``Dak/initialize(appId:baseURL:options:)``.
final class DakRuntime: DakClientEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var clientValue: DakClient?
    private var optionsValue = DakOptions()
    private var logValue = DakLog(debug: false)
    private var appGroupValue: DakAppGroup?

    // Before initialize.
    private var pendingOpens: [DakPendingOpen] = []
    private var pendingReceipts: [String] = []
    private var pendingToken: String?

    let opened = DakOpenedListeners()
    let foreground = DakListeners<DakForegroundListener>()
    let errors = DakListeners<DakErrorListener>()
    let inAppClicks = DakListeners<DakInAppClickListener>()
    /// Whether in-app messages are paused, readable from any thread.
    let inAppPaused = Locked(false)
    let deviceIds: DakDeviceIdListeners
    let foregroundChooser = Locked<(@Sendable (DakNotification) -> UNNotificationPresentationOptions)?>(nil)
    let protectedData = Locked(true)

    /// Message ids already handled in this process: a response reaches the
    /// SDK once per delegate that passes it on.
    private let openedIds = Locked<[String]>([])
    private let shownIds = Locked<[String]>([])

    // Setup checks (debug builds).
    var delegateProxy: DakNotificationCenterDelegate?
    let tokenState = Locked<TokenState>(.none)
    var warned = Set<String>()
    var observers: [NSObjectProtocol] = []

    enum TokenState { case none, asked(Date), got, failed }

    init() {
        let current = Locked<DakClient?>(nil)
        installed = current
        deviceIds = DakDeviceIdListeners { current.value?.currentDeviceId }
    }

    /// The client for the device id listeners, which may ask from any thread.
    private let installed: Locked<DakClient?>

    var client: DakClient? { lock.lock(); defer { lock.unlock() }; return clientValue }
    var options: DakOptions { lock.lock(); defer { lock.unlock() }; return optionsValue }
    var log: DakLog { lock.lock(); defer { lock.unlock() }; return logValue }
    var appGroup: DakAppGroup? { lock.lock(); defer { lock.unlock() }; return appGroupValue }

    /// Sets the client once and hands it what came before; false when there
    /// already is one.
    func install(_ client: DakClient, options: DakOptions, log: DakLog, appGroup: DakAppGroup?) -> Bool {
        lock.lock()
        if clientValue != nil {
            lock.unlock()
            return false
        }
        clientValue = client
        installed.value = client
        optionsValue = options
        logValue = log
        appGroupValue = appGroup
        let opens = pendingOpens
        let receipts = pendingReceipts
        let token = pendingToken
        pendingOpens = []
        pendingReceipts = []
        pendingToken = nil
        lock.unlock()
        client.start()
        for o in opens { client.addOpen(o.id, action: o.action) }
        for r in receipts { client.addReceipt(r) }
        if let token { client.onNewToken(token) }
        return true
    }

    func token(_ hex: String) {
        tokenState.value = .got
        lock.lock()
        guard let client = clientValue else {
            pendingToken = hex
            lock.unlock()
            return
        }
        lock.unlock()
        client.onNewToken(hex)
    }

    /// A tap: counted once, and the listeners get it.
    func tap(_ n: DakNotification) {
        guard let id = n.id, Self.first(id, in: openedIds) else { return }
        lock.lock()
        if let client = clientValue {
            lock.unlock()
            client.addOpen(id, action: n.actionId)
        } else {
            pendingOpens.append(DakPendingOpen(id: id, action: n.actionId))
            lock.unlock()
        }
        opened.dispatch(n)
    }

    /// A push the app saw (in the foreground, or silent): the receipt, and the
    /// foreground listeners when [listeners].
    func arrived(_ n: DakNotification, listeners: Bool, callback: DakCallback? = nil) {
        guard let id = n.id else { return }
        let first = Self.first(id, in: shownIds)
        lock.lock()
        if let client = clientValue {
            lock.unlock()
            client.addReceipt(id, callback: callback)
        } else {
            if first { pendingReceipts.append(id) }
            lock.unlock()
            callback?(nil)
        }
        guard first, listeners else { return }
        let all = foreground.all
        if !all.isEmpty { DispatchQueue.main.async { for l in all { l(n) } } }
    }

    func presentation(for n: DakNotification) -> UNNotificationPresentationOptions {
        foregroundChooser.value?(n) ?? options.foregroundPresentation
    }

    /// True the first time [id] comes; the last 100 are remembered.
    private static func first(_ id: String, in seen: Locked<[String]>) -> Bool {
        seen.update { ids in
            if ids.contains(id) { return false }
            ids.append(id)
            if ids.count > 100 { ids.removeFirst(ids.count - 100) }
            return true
        }
    }

    // MARK: - DakClientEvents

    func deviceId(_ id: String) {
        deviceIds.dispatch(id)
        // In-app messages wait for the device: fetch its list.
        DispatchQueue.main.async { MainActor.assumeIsolated { Dak.inApp.controller?.onRegistered() } }
    }

    /// A tap on an in-app message, for the listeners.
    func inAppClick(_ click: DakInAppClick) {
        let all = inAppClicks.all
        if !all.isEmpty { DispatchQueue.main.async { for l in all { l(click) } } }
    }

    func error(_ error: DakError) {
        let all = errors.all
        if !all.isEmpty { DispatchQueue.main.async { for l in all { l(error) } } }
    }

    /// Logs [message] once per [key] (setup mistakes, debug builds).
    func warnOnce(_ key: String, _ message: String) {
        lock.lock()
        let first = warned.insert(key).inserted
        lock.unlock()
        if first { log.w(message) }
    }
}

/// Runs [f] on the main thread: now when already there.
func onMain(_ f: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(f)
    } else {
        DispatchQueue.main.async(execute: f)
    }
}
