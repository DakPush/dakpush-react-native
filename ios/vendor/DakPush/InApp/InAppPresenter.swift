import UIKit

/// Shows the controller's ``InAppController/current`` message on screen, in
/// a window of its own above the app (UIKit, so SwiftUI apps get it too).
///
/// Every window scene in the foreground is a host; the message shows in the
/// active host's scene. A scene that goes to the background or away hides
/// the message (not counted as dismissed), and it moves to another scene in
/// the foreground or comes back with this one.
@MainActor
final class InAppPresenter {
    private let controller: InAppController
    private let images: InAppImages
    var theme = DakInAppTheme()

    private struct Shown {
        let id: String
        let host: AnyHashable
        let window: InAppWindow
        let controller: InAppViewController
        /// The app window that was key before a modal message took it.
        weak var previousKey: UIWindow?
        /// What had the keyboard focus before a modal message took it.
        weak var responder: UIResponder?
    }

    private var shown: Shown?
    /// Windows on their way out.
    private var leaving: [InAppWindow] = []
    private var loading: (id: String, host: AnyHashable)?
    private var token = 0
    private var keyboardFrame: CGRect?
    private var observers: [NSObjectProtocol] = []

    init(controller: InAppController, images: InAppImages = InAppImages()) {
        self.controller = controller
        self.images = images
    }

    /// The host key of a scene.
    static func host(_ scene: UIScene) -> AnyHashable { AnyHashable(ObjectIdentifier(scene)) }

    func start() {
        controller.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ handle: @escaping @MainActor (InAppPresenter, UIScene) -> Void) {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let scene = note.object as? UIScene
                    MainActor.assumeIsolated {
                        if let self, let scene { handle(self, scene) }
                    }
                })
        }
        on(UIScene.willEnterForegroundNotification) { p, scene in p.attach(scene) }
        on(UIScene.didActivateNotification) { p, scene in
            p.attach(scene)
            p.controller.prefer(Self.host(scene))
        }
        on(UIScene.didEnterBackgroundNotification) { p, scene in p.controller.detach(Self.host(scene)) }
        on(UIScene.didDisconnectNotification) { p, scene in p.controller.detach(Self.host(scene)) }

        // Where the keyboard is, so messages stay above it.
        observers.append(
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) {
                [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                MainActor.assumeIsolated { self?.keyboard(frame, duration) }
            })
        observers.append(
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) {
                [weak self] note in
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                MainActor.assumeIsolated { self?.keyboard(nil, duration) }
            })

        // Scenes already in the foreground (Dak.initialize after launch).
        for scene in UIApplication.shared.connectedScenes
        where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
            attach(scene)
        }
        if let active = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) {
            controller.prefer(Self.host(active))
        }
    }

    private func attach(_ scene: UIScene) {
        guard scene is UIWindowScene else { return }
        controller.attach(Self.host(scene))
    }

    private func scene(_ host: AnyHashable) -> UIWindowScene? {
        UIApplication.shared.connectedScenes.first { Self.host($0) == host } as? UIWindowScene
    }

    private func keyboard(_ frame: CGRect?, _ duration: TimeInterval) {
        keyboardFrame = frame.flatMap { $0.height > 0 ? $0 : nil }
        shown?.controller.keyboardChanged(keyboardFrame, duration: duration)
    }

    // MARK: - Showing

    /// The controller's message or host changed.
    private func changed() {
        guard let m = controller.current, let host = controller.activeHost, let scene = scene(host) else {
            token += 1
            loading = nil
            hide()
            return
        }
        if let s = shown, s.id == m.id, s.host == host { return }
        if let l = loading, l.id == m.id, l.host == host { return }
        hide()
        token += 1
        let t = token
        guard m.content.hasImage, let url = m.content.imageURL else {
            loading = nil
            return show(m, as: m, image: nil, in: scene, host: host)
        }
        loading = (m.id, host)
        let screen = scene.screen
        let pixels = InAppImages.maxPixels(m.layout, screen: screen.bounds.size, scale: screen.scale)
        images.load(url, maxPixels: pixels) { [weak self] image in
            guard let self, t == self.token, self.controller.current?.id == m.id, self.controller.activeHost == host,
                let scene = self.scene(host)
            else { return }
            self.loading = nil
            if let image {
                self.show(m, as: m, image: image, in: scene, host: host)
            } else if m.content.hasText {
                // A message with text shows without the image.
                self.show(m, as: m.withoutImage(), image: nil, in: scene, host: host)
            } else {
                // Nothing else to show: skipped for this session.
                self.controller.didFail(m)
            }
        }
    }

    /// Shows [drawn] (the message, or it without its image) for [m].
    private func show(_ m: InAppMessage, as drawn: InAppMessage, image: UIImage?, in scene: UIWindowScene, host: AnyHashable) {
        let appWindow = Self.appWindow(in: scene)
        let window = InAppWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        window.passThrough = drawn.layout.isBanner
        if let appWindow {
            window.overrideUserInterfaceStyle = appWindow.overrideUserInterfaceStyle
            window.tintColor = appWindow.tintColor
        }
        window.accessibilityIdentifier = "dak-in-app-window"
        let vc = InAppViewController(
            message: drawn, image: image, theme: theme, appTop: Self.topViewController(appWindow?.rootViewController))
        vc.keyboardFrame = keyboardFrame
        vc.onClick = { [weak self] button in self?.controller.click(m, button: button) }
        vc.onDismiss = { [weak self] in self?.controller.dismiss(m) }
        window.rootViewController = vc

        var previousKey: UIWindow?
        var responder: UIResponder?
        if !drawn.layout.isBanner {
            // A modal message takes the keyboard focus, like a dialog, and
            // gives it back when it closes.
            previousKey = scene.windows.first { $0.isKeyWindow && !($0 is InAppWindow) }
            responder = Self.firstResponder(in: scene)
            responder?.resignFirstResponder()
            window.accessibilityViewIsModal = true
        }
        window.isHidden = false
        if !drawn.layout.isBanner {
            window.makeKey()
            vc.becomeFirstResponder()
        }
        vc.animateIn()
        shown = Shown(
            id: m.id, host: host, window: window, controller: vc, previousKey: previousKey, responder: responder)

        // Counted once it is on screen: an app in the background draws nothing.
        DispatchQueue.main.async { [weak self] in
            guard let self, let s = self.shown, s.window === window, self.controller.current?.id == m.id,
                scene.activationState != .background, scene.activationState != .unattached
            else { return }
            self.controller.didDisplay(m)
            self.announce(vc)
        }
    }

    /// VoiceOver: a modal message reads like a dialog; a banner is read out
    /// when it appears.
    private func announce(_ vc: InAppViewController) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        if vc.blocking {
            UIAccessibility.post(notification: .screenChanged, argument: vc.firstElement)
        } else if !vc.announcement.isEmpty {
            UIAccessibility.post(notification: .announcement, argument: vc.announcement)
        }
    }

    private func hide() {
        guard let s = shown else { return }
        shown = nil
        let window = s.window
        // Touches go to the app while it fades out.
        window.isUserInteractionEnabled = false
        leaving.append(window)
        if window.isKeyWindow { s.previousKey?.makeKey() }
        if let r = s.responder as? UIView, r.window != nil, r.canBecomeFirstResponder {
            r.becomeFirstResponder()
        }
        s.controller.animateOut { [weak self] in
            window.isHidden = true
            window.rootViewController = nil
            self?.leaving.removeAll { $0 === window }
        }
    }

    // MARK: - The app's windows

    /// The app's window in [scene] that its content is in: the key one, else
    /// the frontmost normal one.
    static func appWindow(in scene: UIWindowScene) -> UIWindow? {
        let windows = scene.windows.filter { !($0 is InAppWindow) && !$0.isHidden }
        return windows.first { $0.isKeyWindow }
            ?? windows.filter { $0.windowLevel == .normal }.last
            ?? windows.last
    }

    /// The view controller that decides the orientation and status bar now.
    static func topViewController(_ root: UIViewController?) -> UIViewController? {
        var vc = root
        while let presented = vc?.presentedViewController, !presented.isBeingDismissed { vc = presented }
        while let child = vc?.childForStatusBarStyle { vc = child }
        return vc
    }

    /// The view with the keyboard focus in [scene]'s app windows, if any.
    static func firstResponder(in scene: UIWindowScene) -> UIResponder? {
        func find(_ view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        for window in scene.windows where !(window is InAppWindow) && !window.isHidden {
            if let hit = find(window) { return hit }
        }
        return nil
    }

    /// Stops following scenes and the keyboard, and takes the message off
    /// screen (tests).
    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        controller.onChange = nil
        token += 1
        loading = nil
        hide()
    }

    /// For tests: the message on screen.
    var shownController: InAppViewController? { shown?.controller }
    var shownWindow: UIWindow? { shown?.window }
}
