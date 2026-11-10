import Foundation
import UserNotifications

/// A notification button, as the message was sent.
public struct DakButton: Sendable, Equatable {
    /// The button's id, as ``DakNotification/actionId`` reports a tap on it.
    public let id: String
    /// The button's label.
    public let text: String
    /// The deep link for this button, if it has its own.
    public let url: String?
}

/// A push notification as the app sees it.
public struct DakNotification: Sendable, Equatable {
    /// The message's id on the DakPush server.
    public let id: String?
    /// The title, or nil for a silent push.
    public let title: String?
    /// The text, or nil for a silent push.
    public let body: String?
    /// The deep link: the tapped button's own URL if it has one, otherwise
    /// the message's `url`. The SDK never opens it; route it in your opened
    /// listener.
    public let url: String?
    /// The notification's image (`image` when it was sent), if any.
    public let imageURL: String?
    /// The message's data, without the SDK's own `_dak_` keys.
    public let data: [String: String]
    /// The message's buttons.
    public let buttons: [DakButton]
    /// The id of the button the user tapped, or nil for a tap on the
    /// notification itself (and for messages that were not opened).
    public let actionId: String?
    /// The push's top-level string values as they came, `_dak_` keys included.
    public let raw: [String: String]

    /// A silent push has neither title nor body.
    public var isSilent: Bool { title == nil && body == nil }

    static let idKey = "_dak_id"
    static let urlKey = "_dak_url"
    static let buttonsKey = "_dak_buttons"
    static let imageKey = "_dak_image"
    private static let dakPrefix = "_dak_"

    /// Builds a notification from a push's payload. [title] and [body] come
    /// from the shown notification's content.
    init(userInfo: [AnyHashable: Any], title: String? = nil, body: String? = nil, actionId: String? = nil) {
        var raw: [String: String] = [:]
        for (k, v) in userInfo {
            if let k = k as? String, let v = v as? String { raw[k] = v }
        }
        let buttons = Self.parseButtons(raw[Self.buttonsKey])
        var url = raw[Self.urlKey]
        if let actionId, let own = buttons.first(where: { $0.id == actionId })?.url { url = own }
        let image = (userInfo["fcm_options"] as? [String: Any])?["image"] as? String ?? raw[Self.imageKey]
        self.id = raw[Self.idKey].flatMap { $0.isEmpty ? nil : $0 }
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
        self.body = body.flatMap { $0.isEmpty ? nil : $0 }
        self.url = url
        self.imageURL = image
        self.data = raw.filter { !$0.key.hasPrefix(Self.dakPrefix) }
        self.buttons = buttons
        self.actionId = actionId
        self.raw = raw
    }

    init(content: UNNotificationContent, actionId: String? = nil) {
        self.init(userInfo: content.userInfo, title: content.title, body: content.body, actionId: actionId)
    }

    /// True for pushes sent through DakPush.
    static func isDak(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[idKey] as? String)?.isEmpty == false
    }

    /// The buttons from their JSON. Entries without an id are skipped; empty
    /// when there are none or the JSON is bad.
    static func parseButtons(_ json: String?) -> [DakButton] {
        guard let data = json?.data(using: .utf8),
            let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return list.compactMap { entry in
            guard let b = entry as? [String: Any], let id = b["id"] as? String, !id.isEmpty else { return nil }
            let url = (b["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return DakButton(id: id, text: b["text"] as? String ?? "", url: url)
        }
    }
}

extension DakNotification: CustomStringConvertible {
    public var description: String {
        "DakNotification(id: \(id ?? "nil"), title: \(title ?? "nil"), url: \(url ?? "nil"), action: \(actionId ?? "nil"), data: \(data))"
    }
}
