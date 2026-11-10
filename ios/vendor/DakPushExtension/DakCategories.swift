import Foundation
import UserNotifications

/// The notification center calls the category code makes: the system's in
/// the app and the extension, a fake in tests.
@_spi(DakInternal) public protocol DakCategoryCenter: AnyObject {
    /// The registered categories; waits for iOS at most two seconds.
    func notificationCategories() -> Set<UNNotificationCategory>
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

@_spi(DakInternal) public final class DakSystemCategoryCenter: DakCategoryCenter {
    private let center: UNUserNotificationCenter

    public init(_ center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func notificationCategories() -> Set<UNNotificationCategory> {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        center.getNotificationCategories { categories in
            box.value = categories
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return box.value
    }

    public func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    private final class Box: @unchecked Sendable {
        var value = Set<UNNotificationCategory>()
    }
}

/// Buttons on iOS are a notification category's actions. The extension makes
/// a category for each set of buttons and names it the way the Dak server
/// names it in `aps.category` (internal/apns Category): "dak_" and an FNV-1a
/// hash of the buttons' ids and texts in base 36. Both must stay byte for
/// byte the same.
@_spi(DakInternal) public enum DakCategories {
    public static let prefix = "dak_"

    /// Dak categories kept at most, the most recently used.
    public static let maxKept = 30

    /// Category changes one at a time: two pushes at once would each write the
    /// categories they read, and one push's buttons would be lost.
    static let queue = DispatchQueue(label: "dakpush.categories")

    /// The buttons of `_dak_buttons`: the first three, of which those with an
    /// id and a text.
    public static func buttons(fromJSON json: String) -> [(id: String, text: String)] {
        guard let data = json.data(using: .utf8),
            let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return list.prefix(3).compactMap { entry in
            guard let b = entry as? [String: Any], let id = b["id"] as? String, let text = b["text"] as? String,
                !id.isEmpty, !text.isEmpty
            else { return nil }
            return (id, text)
        }
    }

    /// The category's name for these buttons.
    public static func name(for buttons: [(id: String, text: String)]) -> String {
        let key = buttons.map { "\($0.id)\u{1}\($0.text)" }.joined(separator: "\u{2}")
        return prefix + fnv1a(key)
    }

    /// The category for a push's `_dak_buttons`, or nil without buttons. Each
    /// button opens the app, which reports the tap.
    public static func category(forButtonsJSON json: String) -> UNNotificationCategory? {
        let buttons = buttons(fromJSON: json)
        guard !buttons.isEmpty else { return nil }
        let actions = buttons.map { UNNotificationAction(identifier: $0.id, title: $0.text, options: [.foreground]) }
        return UNNotificationCategory(identifier: name(for: buttons), actions: actions, intentIdentifiers: [], options: [])
    }

    /// A hash that is the same in every process (Swift's hashValue is not).
    static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// Adds [category], keeping the app's own categories and Dak's most
    /// recently used ones, and returns once iOS has it: the notification is
    /// shown right after, and without its category it would have no buttons.
    public static func register(
        _ category: UNNotificationCategory, center: DakCategoryCenter, group: DakAppGroup?,
        pollInterval: useconds_t = 30_000
    ) {
        queue.sync {
            let id = category.identifier
            let existing = center.notificationCategories()
            // Most recently used last. Dak categories the list does not know
            // (made before it, or without an App Group) count as the oldest.
            var recent = (group?.savedCategories ?? []).compactMap { $0["id"] as? String }
            let unknown = existing.map(\.identifier).filter { $0.hasPrefix(prefix) && !recent.contains($0) }.sorted()
            recent = unknown + recent
            recent.removeAll { $0 == id }
            recent.append(id)
            let kept = Array(recent.suffix(maxKept))
            let keep = Set(kept)

            var categories = existing.filter {
                $0.identifier != id && (!$0.identifier.hasPrefix(prefix) || keep.contains($0.identifier))
            }
            categories.insert(category)
            center.setNotificationCategories(categories)
            // setNotificationCategories returns before iOS has the new set.
            for _ in 0..<10 {
                if center.notificationCategories().contains(where: { $0.identifier == id }) { break }
                usleep(pollInterval)
            }

            // For the app, which puts them back if something replaces them all.
            let byId = Dictionary(categories.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
            group?.savedCategories = kept.compactMap { cid in
                guard let c = byId[cid] else { return nil }
                return ["id": cid, "actions": c.actions.map { ["id": $0.identifier, "title": $0.title] }]
            }
        }
    }

    /// The app's side: puts back the categories the extension made when they
    /// are gone, for example after the app or a library set only its own.
    public static func restore(center: DakCategoryCenter, group: DakAppGroup) {
        let saved = group.savedCategories
        guard !saved.isEmpty else { return }
        queue.sync {
            let existing = center.notificationCategories()
            let have = Set(existing.map(\.identifier))
            let missing: [UNNotificationCategory] = saved.compactMap { entry in
                guard let id = entry["id"] as? String, !have.contains(id),
                    let list = entry["actions"] as? [[String: String]]
                else { return nil }
                let actions = list.compactMap { a -> UNNotificationAction? in
                    guard let aid = a["id"], let title = a["title"] else { return nil }
                    return UNNotificationAction(identifier: aid, title: title, options: [.foreground])
                }
                return actions.isEmpty
                    ? nil : UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
            }
            if !missing.isEmpty { center.setNotificationCategories(existing.union(missing)) }
        }
    }
}
