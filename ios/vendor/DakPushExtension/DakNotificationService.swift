import Foundation
import UserNotifications

/// The notification service extension for DakPush. It runs for every push
/// before iOS shows it, and:
///
/// - reports the delivery to the app's Dak server ("delivered" count,
///   webhooks), or keeps it in the App Group for the app to send;
/// - attaches the push's image (at most 5 MB, within 8 seconds);
/// - adds its buttons, as a notification category made on the fly;
/// - counts badge increments.
///
/// In the extension target:
///
/// ```swift
/// import DakPushExtension
///
/// class NotificationService: DakNotificationService {}
/// ```
///
/// and put the App Group the app and the extension share under `DakAppGroup`
/// in the extension's Info.plist (or override ``appGroupIdentifier``).
open class DakNotificationService: UNNotificationServiceExtension {
    private var processor: DakNotificationProcessor?

    /// The App Group shared with the app. By default the `DakAppGroup` value
    /// of the extension's Info.plist.
    open var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "DakAppGroup") as? String
    }

    open override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let processor = DakNotificationProcessor(
            group: DakNotificationProcessor.appGroup(appGroupIdentifier), center: DakSystemCategoryCenter())
        self.processor = processor
        processor.process(request) { [weak self] content in
            self?.willDeliver(content, for: request)
            contentHandler(content)
        }
    }

    open override func serviceExtensionTimeWillExpire() {
        processor?.finishNow()
    }

    /// Called once with the content just before iOS gets it, image and
    /// buttons already in, for changes of your own. Keep it quick.
    open func willDeliver(_ content: UNMutableNotificationContent, for request: UNNotificationRequest) {}
}

/// What ``DakNotificationService`` does to one push, with its dependencies
/// passed in (tests use fakes).
@_spi(DakInternal) public final class DakNotificationProcessor: @unchecked Sendable {
    private let group: DakAppGroup?
    private let center: DakCategoryCenter?
    private let protocolClasses: [AnyClass]?
    private let receiptTimeout: TimeInterval
    private let lock = NSLock()
    private var content: UNMutableNotificationContent?
    private var completion: ((UNMutableNotificationContent) -> Void)?
    private var finished = false

    public init(
        group: DakAppGroup?, center: DakCategoryCenter?, protocolClasses: [AnyClass]? = nil,
        receiptTimeout: TimeInterval = 10
    ) {
        self.group = group
        self.center = center
        self.protocolClasses = protocolClasses
        self.receiptTimeout = receiptTimeout
    }

    /// The App Group's defaults. A setup mistake is logged (Console.app,
    /// subsystem dakpush): without the group no delivery is reported.
    public static func appGroup(_ identifier: String?) -> DakAppGroup? {
        guard let identifier, !identifier.isEmpty else {
            dakExtensionLog.error("DakPush: no DakAppGroup in the extension's Info.plist")
            return nil
        }
        guard let group = DakAppGroup(identifier: identifier) else {
            dakExtensionLog.error(
                "DakPush: App Group \(identifier, privacy: .public) is not in the extension's entitlements (Signing & Capabilities → App Groups)"
            )
            return nil
        }
        return group
    }

    /// [completion] gets the content once: when everything is done, or at
    /// ``finishNow()``.
    public func process(
        _ request: UNNotificationRequest, completion: @escaping (UNMutableNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return }
        lock.lock()
        self.content = content
        self.completion = completion
        lock.unlock()
        let info = content.userInfo
        let work = DispatchGroup()

        if let group {
            group.extensionSchema = DakAppGroup.schema
            if group.appSchema > DakAppGroup.schema {
                dakExtensionLog.error(
                    "DakPush: the app's SDK is newer than the extension's (schema \(group.appSchema) > \(DakAppGroup.schema)); update DakPushExtension"
                )
            }
            applyBadge(info: info, group: group)
        }
        if let buttons = info["_dak_buttons"] as? String, let center,
            let category = DakCategories.category(forButtonsJSON: buttons)
        {
            work.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                DakCategories.register(category, center: center, group: self.group)
                self.edit { $0.categoryIdentifier = category.identifier }
                work.leave()
            }
        }
        if let image = Self.imageURL(info) {
            work.enter()
            attachImage(image) { work.leave() }
        }
        if let id = info["_dak_id"] as? String, !id.isEmpty, let group {
            work.enter()
            reportDelivered(messageId: id, group: group) { work.leave() }
        }
        work.notify(queue: .global()) { self.finishNow() }
    }

    /// Hands the content over as it is now; later changes are dropped.
    public func finishNow() {
        lock.lock()
        guard !finished, let content, let completion else {
            lock.unlock()
            return
        }
        finished = true
        self.completion = nil
        lock.unlock()
        completion(content)
    }

    /// False when the content was already handed over (time ran out).
    @discardableResult
    private func edit(_ change: (UNMutableNotificationContent) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let content else { return false }
        change(content)
        return true
    }

    // MARK: - Delivery receipt

    private func reportDelivered(messageId: String, group: DakAppGroup, done: @escaping () -> Void) {
        guard let config = group.config,
            let url = URL(string: "\(config.baseURL)/v1/apps/\(config.appId)/devices/\(config.deviceId)/delivered")
        else {
            dakExtensionLog.info("DakPush: the app has not registered yet; the receipt is kept for it")
            group.keepReceipt(messageId)
            done()
            return
        }
        var request = URLRequest(url: url, timeoutInterval: receiptTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DakPushInfo.userAgent, forHTTPHeaderField: "User-Agent")
        // The receipt token can only report deliveries; the device secret stays
        // in the app's keychain.
        request.setValue("Receipt \(config.receiptToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["message_id": messageId])
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForResource = receiptTimeout
        sessionConfig.waitsForConnectivity = false
        if let protocolClasses { sessionConfig.protocolClasses = protocolClasses }
        let session = URLSession(configuration: sessionConfig)
        session.dataTask(with: request) { _, response, _ in
            // Kept for the app (it sends them on its next start or resume)
            // unless the server took it or refused it for good.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let refused = (400..<500).contains(status) && ![401, 408, 429].contains(status)
            if !(200..<300).contains(status) && !refused { group.keepReceipt(messageId) }
            done()
        }.resume()
        session.finishTasksAndInvalidate()
    }

    // MARK: - Badge

    private func applyBadge(info: [AnyHashable: Any], group: DakAppGroup) {
        if let raw = info["_dak_badge_inc"] as? String, let inc = Int(raw) {
            let count = max(0, group.badge + inc)
            group.badge = count
            edit { $0.badge = NSNumber(value: count) }
        } else if let aps = info["aps"] as? [String: Any], let badge = aps["badge"] as? Int {
            group.badge = badge
        }
    }

    // MARK: - Image

    /// Dak puts the image where Firebase does, at fcm_options.image.
    static func imageURL(_ info: [AnyHashable: Any]) -> URL? {
        let options = info["fcm_options"] as? [String: Any]
        guard let raw = options?["image"] as? String ?? info["_dak_image"] as? String,
            let url = URL(string: raw), url.scheme == "https"
        else { return nil }
        return url
    }

    private func attachImage(_ url: URL, done: @escaping () -> Void) {
        DakImageDownload.start(url, protocolClasses: protocolClasses) { file in
            defer { done() }
            guard let file else { return }
            var attached = false
            if let attachment = try? UNNotificationAttachment(identifier: "image", url: file, options: nil) {
                attached = self.edit { $0.attachments = [attachment] }
            }
            // iOS moves an attached file away; one it never got is ours to delete.
            if !attached { try? FileManager.default.removeItem(at: file) }
        }
    }
}
