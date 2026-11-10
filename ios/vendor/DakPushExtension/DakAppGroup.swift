import Foundation
import os

/// The SDK's version and the User-Agent both modules send.
@_spi(DakInternal) public enum DakPushInfo {
    public static let version = "0.2.0"
    public static let userAgent = "dakpush-ios/\(version)"
}

@_spi(DakInternal) public let dakExtensionLog = Logger(subsystem: "dakpush", category: "extension")

/// What the app and its notification service extension share through their
/// App Group's defaults. The keys and the schema are the Flutter SDK's, so an
/// extension built for either works with both.
@_spi(DakInternal) public struct DakAppGroup {
    /// What the app and the extension agree on; bump it when the keys change.
    public static let schema = 2
    static let configKey = "dak_push"
    static let badgeKey = "dak_push_badge"
    static let schemaKey = "dak_push_schema"
    static let extensionSchemaKey = "dak_push_extension_schema"
    static let receiptPrefix = "dak_push_receipt."
    static let categoriesKey = "dak_push_categories"

    /// How many receipts the extension keeps for the app at most.
    public static let maxKeptReceipts = 200

    public let identifier: String
    public let defaults: UserDefaults

    /// The group's defaults, or nil when this app or extension is not
    /// entitled to the group: then the other side could never read what is
    /// written.
    public init?(identifier: String) {
        guard !identifier.isEmpty,
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil,
            let defaults = UserDefaults(suiteName: identifier)
        else { return nil }
        self.init(identifier: identifier, defaults: defaults)
    }

    /// For tests: any defaults.
    public init(identifier: String, defaults: UserDefaults) {
        self.identifier = identifier
        self.defaults = defaults
    }

    // MARK: - Settings for delivery receipts

    /// What the extension needs to report deliveries. Only the receipt token,
    /// which can do nothing else, never the device secret.
    public struct Config: Equatable {
        public var baseURL: String
        public var appId: String
        public var deviceId: String
        public var receiptToken: String

        public init(baseURL: String, appId: String, deviceId: String, receiptToken: String) {
            self.baseURL = baseURL
            self.appId = appId
            self.deviceId = deviceId
            self.receiptToken = receiptToken
        }
    }

    public var config: Config? {
        guard let values = defaults.dictionary(forKey: Self.configKey) as? [String: String],
            let base = values["base_url"], let app = values["app_id"],
            let device = values["device_id"], let token = values["receipt_token"]
        else { return nil }
        return Config(baseURL: base, appId: app, deviceId: device, receiptToken: token)
    }

    /// The app's side.
    public func share(_ config: Config) {
        defaults.set(
            [
                "base_url": config.baseURL, "app_id": config.appId,
                "device_id": config.deviceId, "receipt_token": config.receiptToken,
            ], forKey: Self.configKey)
        defaults.set(Self.schema, forKey: Self.schemaKey)
    }

    /// The device is gone: the extension stops reporting until the next share.
    public func removeConfig() {
        defaults.removeObject(forKey: Self.configKey)
    }

    // MARK: - Receipts the extension could not send

    /// One key per receipt, so the app taking receipts and the extension
    /// keeping one never overwrite each other.
    public func keepReceipt(_ messageId: String) {
        let kept = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.receiptPrefix) }.count
        if kept < Self.maxKeptReceipts { defaults.set(true, forKey: Self.receiptPrefix + messageId) }
    }

    public var keptReceipts: [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.receiptPrefix) }
            .map { String($0.dropFirst(Self.receiptPrefix.count)) }
            .sorted()
    }

    public func removeReceipts(_ messageIds: [String]) {
        for id in messageIds { defaults.removeObject(forKey: Self.receiptPrefix + id) }
    }

    // MARK: - Badge

    /// The app icon's badge as the app last set it, for badge increments.
    public var badge: Int {
        get { defaults.integer(forKey: Self.badgeKey) }
        nonmutating set { defaults.set(max(0, newValue), forKey: Self.badgeKey) }
    }

    // MARK: - Schemas

    /// The schema of the app's SDK, 0 before it shared anything.
    public var appSchema: Int { defaults.integer(forKey: Self.schemaKey) }

    /// The schema of the extension, 0 before its first push.
    public var extensionSchema: Int {
        get { defaults.integer(forKey: Self.extensionSchemaKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.extensionSchemaKey) }
    }

    // MARK: - Button categories

    /// Dak's categories, most recently used last, as the extension saved them:
    /// id and actions (id, title).
    public var savedCategories: [[String: Any]] {
        get { defaults.array(forKey: Self.categoriesKey) as? [[String: Any]] ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.categoriesKey) }
    }
}
