import Foundation

// The in-app messages as the server sends them (GET …/devices/{id}/in-app).
// A port of the Flutter SDK's lib/src/in_app/model.dart: anything this SDK
// version does not understand (a newer layout, action or trigger) or cannot
// read (a field of the wrong type) skips that one message, never the list.

/// How a message is laid out on screen.
enum InAppLayout: String, CaseIterable {
    /// A centred dialog over a dimmed app.
    case modal
    /// A banner at the top; the app stays usable.
    case bannerTop = "banner_top"
    /// A banner at the bottom; the app stays usable.
    case bannerBottom = "banner_bottom"
    /// A page that covers the app.
    case fullscreen
    /// A card that slides up from the bottom.
    case card

    var isBanner: Bool { self == .bannerTop || self == .bannerBottom }
}

/// What a click does.
struct InAppAction: Equatable {
    let type: DakInAppActionType
    /// For deep_link and url.
    let url: String?
    /// For tags: tags to set; an empty value removes the tag.
    let tags: [String: String]

    /// Nil for an action type this SDK does not know; throws for a field of
    /// the wrong type.
    static func parse(_ js: JSON?) throws -> InAppAction? {
        guard let o = js?.object, let raw = o["type"]?.string, let type = DakInAppActionType(rawValue: raw) else {
            return nil
        }
        var tags: [String: String] = [:]
        if let t = o["tags"]?.object {
            for (k, v) in t { tags[k] = InAppParse.text(v) }
        }
        return InAppAction(type: type, url: try InAppParse.string(o["url"]), tags: tags)
    }
}

/// A button on a message.
struct InAppButton: Equatable {
    /// The click id: reported in the click listener and counted in the stats.
    let id: String
    let text: String
    let action: InAppAction
    /// 0xAARRGGBB; nil takes the theme's.
    let backgroundColor: UInt32?
    /// 0xAARRGGBB; nil picks one that reads on the background.
    let textColor: UInt32?
}

/// What a message shows.
struct InAppContent: Equatable {
    var title: String?
    var body: String?
    /// https only; loaded before the message shows.
    var imageURL: String?
    var backgroundColor: UInt32?
    var titleColor: UInt32?
    var bodyColor: UInt32?
    /// Whether the message has an X. A fullscreen message with no other way
    /// out gets one anyway.
    var closeButton = true
    /// Banners only: closes by itself after this many seconds.
    var autoDismiss: TimeInterval?
    /// What tapping the message itself does.
    var clickAction: InAppAction?
    /// At most three.
    var buttons: [InAppButton] = []

    var hasTitle: Bool { !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    var hasBody: Bool { !(body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    /// A title or text to show without the image.
    var hasText: Bool { hasTitle || hasBody }

    var hasImage: Bool { !(imageURL?.isEmpty ?? true) }
}

/// One condition of a trigger. A message's triggers are OR-ed groups of
/// AND-ed conditions.
struct InAppCondition: Equatable {
    enum Kind: String {
        case sessionCount = "session_count"
        case sessionTime = "session_time"
        case sinceInstall = "since_install"
        case custom
    }

    let kind: Kind
    /// `=`, `!=`, `>`, `>=`, `<`, `<=`, and for custom also `in`, `exists`,
    /// `not_exists`.
    let op: String
    /// Custom conditions: the trigger key set with Dak.addTrigger.
    let key: String?
    /// A count, seconds, or the trigger value.
    let value: JSON?
    /// For `in`.
    let values: [String]

    private static let ops: [Kind: Set<String>] = [
        .sessionCount: ["=", "!=", ">", ">=", "<", "<="],
        .sessionTime: [">=", "<"],
        .sinceInstall: [">=", "<"],
        .custom: ["=", "!=", ">", ">=", "<", "<=", "in", "exists", "not_exists"],
    ]

    /// Nil for a kind or comparison this SDK does not know.
    static func parse(_ js: JSON) throws -> InAppCondition? {
        guard let o = js.object, let k = o["kind"]?.string, let kind = Kind(rawValue: k), let op = o["op"]?.string,
            ops[kind]?.contains(op) == true
        else { return nil }
        let key = try InAppParse.string(o["key"])
        let value = o["value"].flatMap { $0 == .null ? nil : $0 }
        let values = (o["values"]?.array ?? []).map(InAppParse.text)
        if kind == .custom && (key ?? "").isEmpty { return nil }
        if kind != .custom && value?.number == nil { return nil }
        return InAppCondition(kind: kind, op: op, key: key, value: value, values: values)
    }

    /// The number of a count or time condition.
    var seconds: Double { value?.number ?? 0 }
}

/// How often one device may see a message.
struct InAppFrequency: Equatable {
    enum Kind: String {
        case once
        case everySession = "every_session"
        case interval
    }

    let kind: Kind
    /// For interval: the time between two showings.
    let interval: TimeInterval
    /// At most this many showings in all; nil for no limit.
    let maxDisplays: Int?

    static func parse(_ js: JSON?) throws -> InAppFrequency? {
        guard let o = js?.object, let t = o["type"]?.string, let kind = Kind(rawValue: t) else { return nil }
        return InAppFrequency(
            kind: kind, interval: try InAppParse.number(o["interval_seconds"]) ?? 0,
            maxDisplays: try InAppParse.number(o["max_displays"]).map { Int($0) })
    }
}

/// A message as the server sent it.
struct InAppMessage: Equatable {
    let id: String
    let layout: InAppLayout
    var content: InAppContent
    /// OR-ed groups of AND-ed conditions; empty means "when the app opens".
    let triggers: [[InAppCondition]]
    let frequency: InAppFrequency
    /// The highest shows first.
    let priority: Int
    let startAt: Date?
    let endAt: Date?
    /// How often the server counted this device showing it.
    let shown: Int
    let lastShownAt: Date?

    /// The same message without its image, for when it did not load.
    func withoutImage() -> InAppMessage {
        var m = self
        m.content.imageURL = nil
        return m
    }

    /// The X shows also when the message turned it off but has no other way
    /// out (a fullscreen message with no buttons and nothing to tap: iOS has
    /// no back button).
    var showsClose: Bool {
        content.closeButton
            || (layout == .fullscreen && content.buttons.isEmpty && content.clickAction == nil)
    }

    /// Nil for anything this SDK cannot show or read. Never throws.
    static func parse(_ js: JSON) -> InAppMessage? {
        (try? parseOrThrow(js)) ?? nil
    }

    private static func parseOrThrow(_ js: JSON) throws -> InAppMessage? {
        guard let o = js.object, let id = o["id"]?.string, !id.isEmpty,
            let layout = o["layout"]?.string.flatMap(InAppLayout.init(rawValue:)),
            let c = o["content"]?.object, let frequency = try InAppFrequency.parse(o["frequency"])
        else { return nil }

        var click: InAppAction?
        if let raw = c["click_action"], raw != .null {
            guard let action = try InAppAction.parse(raw) else { return nil }
            click = action
        }
        var buttons: [InAppButton] = []
        if let raw = c["buttons"], raw != .null {
            guard let list = raw.array else { throw InAppParse.WrongType() }
            for b in list {
                guard let bo = b.object, let action = try InAppAction.parse(bo["action"]), let bid = bo["id"]?.string,
                    let text = bo["text"]?.string
                else { return nil }
                buttons.append(
                    InAppButton(
                        id: bid, text: text, action: action, backgroundColor: InAppParse.color(bo["background_color"]),
                        textColor: InAppParse.color(bo["text_color"])))
            }
        }
        let auto = try InAppParse.number(c["auto_dismiss_seconds"]) ?? 0
        var closeButton = true
        if let raw = c["close_button"], raw != .null {
            guard let b = raw.bool else { throw InAppParse.WrongType() }
            closeButton = b
        }
        let content = InAppContent(
            title: try InAppParse.string(c["title"]), body: try InAppParse.string(c["body"]),
            imageURL: try InAppParse.string(c["image_url"]), backgroundColor: InAppParse.color(c["background_color"]),
            titleColor: InAppParse.color(c["title_color"]), bodyColor: InAppParse.color(c["body_color"]),
            closeButton: closeButton, autoDismiss: auto > 0 ? auto : nil, clickAction: click, buttons: buttons)

        var triggers: [[InAppCondition]] = []
        if let raw = o["triggers"], raw != .null {
            guard let groups = raw.array else { throw InAppParse.WrongType() }
            for g in groups {
                guard let list = g.array, !list.isEmpty else { return nil }
                var group: [InAppCondition] = []
                for cond in list {
                    guard let parsed = try InAppCondition.parse(cond) else { return nil }
                    group.append(parsed)
                }
                triggers.append(group)
            }
        }

        return InAppMessage(
            id: id, layout: layout, content: content, triggers: triggers, frequency: frequency,
            priority: Int(try InAppParse.number(o["priority"]) ?? 0), startAt: InAppParse.time(o["start_at"]),
            endAt: InAppParse.time(o["end_at"]), shown: Int(try InAppParse.number(o["shown"]) ?? 0),
            lastShownAt: InAppParse.time(o["last_shown_at"]))
    }
}

/// Reading the server's JSON as strictly as the Flutter SDK does.
enum InAppParse {
    struct WrongType: Error {}

    /// A string, or nil when absent; throws for another type.
    static func string(_ v: JSON?) throws -> String? {
        guard let v, v != .null else { return nil }
        guard let s = v.string else { throw WrongType() }
        return s
    }

    /// A number, or nil when absent; throws for another type.
    static func number(_ v: JSON?) throws -> Double? {
        guard let v, v != .null else { return nil }
        guard let n = v.number else { throw WrongType() }
        return n
    }

    /// Any value as text, as the Flutter SDK's '$v' (whole numbers without
    /// a fraction).
    static func text(_ v: JSON) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .double(let d): return numberText(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    static func numberText(_ d: Double) -> String {
        if d.isFinite, d.rounded() == d, abs(d) < 9.0e15 { return String(Int(d)) }
        return String(d)
    }

    /// `#RRGGBB` or `#AARRGGBB` as 0xAARRGGBB; nil when absent or malformed
    /// (a bad colour is only left out).
    static func color(_ v: JSON?) -> UInt32? {
        guard let s = v?.string, s.hasPrefix("#") else { return nil }
        let hex = s.dropFirst()
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit), let n = UInt32(hex, radix: 16) else {
            return nil
        }
        return hex.count == 6 ? 0xFF00_0000 | n : n
    }

    /// An RFC 3339 time like the server's (Go's, with up to nine fraction
    /// digits); nil when absent or unreadable.
    static func time(_ v: JSON?) -> Date? {
        guard let s = v?.string else { return nil }
        return parseTime(s)
    }

    private static let base: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    static func parseTime(_ s: String) -> Date? {
        // The fraction is cut off and added back: ISO8601DateFormatter reads
        // only three digits of it.
        var text = s.trimmingCharacters(in: .whitespaces)
        var fraction = 0.0
        if let dot = text.firstIndex(of: "."), text.distance(from: text.startIndex, to: dot) == 19 {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isASCII, text[end].isNumber { end = text.index(after: end) }
            fraction = Double("0" + text[dot..<end]) ?? 0
            text.removeSubrange(dot..<end)
        }
        lock.lock()
        defer { lock.unlock() }
        return base.date(from: text).map { $0.addingTimeInterval(fraction) }
    }

    /// UTC with milliseconds, as the server reads it.
    static func formatTime(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
