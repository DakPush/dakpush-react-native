import Foundation
import UIKit

/// In-app state of the facade; main thread only. Calls made before
/// ``Dak/initialize(appId:baseURL:options:)`` are kept and handed over.
@MainActor
final class DakInAppRuntime {
    private(set) var controller: InAppController?
    private(set) var presenter: InAppPresenter?
    var theme = DakInAppTheme() {
        didSet { presenter?.theme = theme }
    }
    private var triggers: [String: InAppTrigger] = [:]
    private var paused = false
    private var blocks = 0

    nonisolated init() {}

    func install(_ controller: InAppController, _ presenter: InAppPresenter) {
        self.controller = controller
        self.presenter = presenter
        presenter.theme = theme
        if !triggers.isEmpty { controller.addTriggers(triggers) }
        if paused { controller.setPaused(true) }
        for _ in 0..<blocks { controller.block() }
        triggers = [:]
    }

    func addTriggers(_ values: [String: InAppTrigger]) {
        if let controller { controller.addTriggers(values) } else { triggers.merge(values) { _, new in new } }
    }

    func removeTriggers(_ keys: [String]) {
        if let controller { controller.removeTriggers(keys) } else { for k in keys { triggers.removeValue(forKey: k) } }
    }

    func clearTriggers() {
        if let controller { controller.clearTriggers() } else { triggers = [:] }
    }

    func setPaused(_ value: Bool) {
        paused = value
        controller?.setPaused(value)
        update()
    }

    func block() {
        blocks += 1
        controller?.block()
        update()
    }

    func unblock() {
        blocks = max(0, blocks - 1)
        controller?.unblock()
        update()
    }

    private func update() {
        Dak.runtime.inAppPaused.value = paused || blocks > 0
    }
}

extension Dak {
    static let inApp = DakInAppRuntime()

    /// Starts in-app messages: called by ``initialize(appId:baseURL:options:)``.
    @MainActor
    static func startInApp(api: DakApi, client: DakClient, options: DakOptions, log: DakLog) {
        let controller = InAppController(
            api: api, store: FileStateStore.standard("in_app.json"),
            credentials: { [weak client] in client?.credentials },
            setTags: { tags in Dak.setTags(tags.mapValues { $0 as Any? }) },
            openURL: { url in MainActor.assumeIsolated { UIApplication.shared.open(url) } },
            urlSchemes: options.inAppUrlSchemes, home: MainQueueScheduler(), io: QueueScheduler(label: "dakpush.inapp"),
            clock: Date.init, log: log,
            isForeground: { MainActor.assumeIsolated { UIApplication.shared.applicationState != .background } },
            sessionTimeout: options.sessionTimeout)
        controller.onClick = { click in runtime.inAppClick(click) }
        let presenter = InAppPresenter(controller: controller)
        inApp.install(controller, presenter)
        presenter.start()
        controller.start()
    }

    // MARK: - In-app messages

    /// Sets a trigger that in-app messages can wait for, such as the screen
    /// the user is on. Triggers stay in memory (not saved, never sent) until
    /// removed or the app ends. A key must be 1-64 of `A-Z a-z 0-9 _ . : -`;
    /// others are ignored with a warning in the log.
    ///
    /// ```swift
    /// Dak.addTrigger("screen", "home")
    /// Dak.addTrigger("lessons_done", 3)
    /// ```
    public static func addTrigger(_ key: String, _ value: DakTriggerValue) {
        addTriggers([key: value])
    }

    /// Sets several triggers at once; see ``addTrigger(_:_:)``.
    public static func addTriggers(_ triggers: [String: DakTriggerValue]) {
        var values: [String: InAppTrigger] = [:]
        for (k, v) in triggers {
            guard tagKeyIsValid(k) else {
                runtime.log.w("DakPush: trigger key \(k) must be 1-64 of A-Z a-z 0-9 _ . : -; ignored")
                continue
            }
            values[k] = InAppTrigger(v)
        }
        if values.isEmpty { return }
        onMain { inApp.addTriggers(values) }
    }

    /// Removes a trigger set with ``addTrigger(_:_:)``.
    public static func removeTrigger(_ key: String) {
        removeTriggers([key])
    }

    /// Removes the triggers with these keys.
    public static func removeTriggers(_ keys: [String]) {
        onMain { inApp.removeTriggers(keys) }
    }

    /// Removes all triggers.
    public static func clearTriggers() {
        onMain { inApp.clearTriggers() }
    }

    /// Keeps in-app messages away (true) until called with false. A message
    /// on screen is hidden, not dismissed, and comes back afterwards. For one
    /// screen, ``blockInApp()`` is simpler.
    public static func pauseInApp(_ paused: Bool) {
        onMain { inApp.setPaused(paused) }
    }

    /// Whether in-app messages are paused, by ``pauseInApp(_:)`` or a
    /// ``DakInAppBlock``.
    public static var isInAppPaused: Bool { runtime.inAppPaused.value }

    /// Keeps in-app messages away until the returned block ends (``DakInAppBlock/end()``
    /// or releasing it), for a screen that must not be covered: a call, a
    /// payment. Blocks nest; messages come back after the last one ends.
    /// SwiftUI: `.dakInAppBlocked()`.
    public static func blockInApp() -> DakInAppBlock {
        onMain { inApp.block() }
        return DakInAppBlock { onMain { inApp.unblock() } }
    }

    /// Calls [listener] for taps on in-app messages and their buttons, on the
    /// main thread. Deep links are yours to route; `url` actions open the
    /// browser and `tags` actions set tags by themselves.
    ///
    /// ```swift
    /// Dak.addInAppClickListener { click in
    ///     if click.actionType == .deepLink, let url = click.link { router.open(url) }
    /// }
    /// ```
    @discardableResult
    public static func addInAppClickListener(_ listener: @escaping DakInAppClickListener) -> DakSubscription {
        runtime.inAppClicks.add(listener)
    }

    /// Taps on in-app messages as an `AsyncStream`; see
    /// ``addInAppClickListener(_:)``. The listener goes when the loop ends.
    ///
    /// ```swift
    /// for await click in Dak.inAppClicks { … }
    /// ```
    public static var inAppClicks: AsyncStream<DakInAppClick> {
        AsyncStream { continuation in
            let subscription = addInAppClickListener { continuation.yield($0) }
            continuation.onTermination = { _ in subscription.remove() }
        }
    }

    /// Fetches the in-app messages now rather than at the next session start
    /// (at most once a minute), then shows one if it is due. [completion]
    /// runs on the main thread when done, also offline.
    public static func refreshInApp(completion: (@MainActor () -> Void)? = nil) {
        onMain {
            guard let controller = inApp.controller else {
                runtime.log.w("DakPush: in-app messages are off: call Dak.initialize first, with DakOptions.inAppMessages on")
                completion?()
                return
            }
            controller.refresh {
                controller.check()
                MainActor.assumeIsolated { completion?() }
            }
        }
    }

    /// See ``refreshInApp(completion:)``.
    public static func refreshInApp() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            refreshInApp { c.resume() }
        }
    }

    /// Colours for in-app messages where a message sets none; see
    /// ``DakInAppTheme``. Takes effect for the next message.
    @MainActor
    public static var inAppTheme: DakInAppTheme {
        get { inApp.theme }
        set { inApp.theme = newValue }
    }

    static func tagKeyIsValid(_ key: String) -> Bool {
        tagKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }
}
