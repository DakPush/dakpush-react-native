import Foundation
import UIKit

/// What a click on an in-app message does. Every click also closes the
/// message and reaches ``Dak/addInAppClickListener(_:)``.
public enum DakInAppActionType: String, Sendable, CaseIterable {
    /// The app routes ``DakInAppClick/url`` (any scheme) in its click listener.
    case deepLink = "deep_link"
    /// The SDK opens ``DakInAppClick/url`` in the browser (`https` and `http`
    /// unless ``DakOptions/inAppUrlSchemes`` allows more).
    case url
    /// The SDK sets ``DakInAppClick/tags`` on the device.
    case tags
    /// Only closes the message.
    case dismiss
    /// Only the click listener, with the button id.
    case custom
}

/// A tap on an in-app message or one of its buttons.
public struct DakInAppClick: Sendable, Equatable, CustomStringConvertible {
    /// The message that was tapped.
    public let messageId: String

    /// The button's id, or nil when the message itself was tapped.
    public let buttonId: String?

    /// What the tap does.
    public let actionType: DakInAppActionType

    /// For ``DakInAppActionType/deepLink`` and ``DakInAppActionType/url``: the
    /// link as the message has it.
    public let url: String?

    /// For ``DakInAppActionType/tags``: the tags the SDK sets (an empty value
    /// removes the tag).
    public let tags: [String: String]

    public init(
        messageId: String, buttonId: String?, actionType: DakInAppActionType, url: String? = nil,
        tags: [String: String] = [:]
    ) {
        self.messageId = messageId
        self.buttonId = buttonId
        self.actionType = actionType
        self.url = url
        self.tags = tags
    }

    /// ``url`` as a URL, or nil when there is none or it is not one.
    public var link: URL? { url.flatMap(URL.init(string:)) }

    public var description: String {
        "DakInAppClick(\(messageId), \(buttonId ?? "-"), \(actionType.rawValue)\(url.map { " \($0)" } ?? ""))"
    }
}

/// Taps on in-app messages. See ``Dak/addInAppClickListener(_:)``.
public typealias DakInAppClickListener = @MainActor (DakInAppClick) -> Void

/// A value for ``Dak/addTrigger(_:_:)``: a string, a number or a boolean.
public protocol DakTriggerValue: Sendable {}

extension String: DakTriggerValue {}
extension Bool: DakTriggerValue {}
extension Int: DakTriggerValue {}
extension Int64: DakTriggerValue {}
extension Int32: DakTriggerValue {}
extension UInt: DakTriggerValue {}
extension Double: DakTriggerValue {}
extension Float: DakTriggerValue {}

/// A trigger value as the SDK compares it.
enum InAppTrigger: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(_ value: DakTriggerValue) {
        switch value {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let i as Int64: self = .number(Double(i))
        case let i as Int32: self = .number(Double(i))
        case let i as UInt: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let f as Float: self = .number(Double(f))
        default: self = .string(String(describing: value))
        }
    }

    /// As text, whole numbers without a fraction.
    var text: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return InAppParse.numberText(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    /// As a number: numbers, and strings that read as one.
    var number: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool: return nil
        }
    }
}

/// Keeps in-app messages away while it lives, for screens that must not be
/// covered (a call, a payment). Get one from ``Dak/blockInApp()``; a message
/// on screen is hidden and comes back after the last block ends.
///
/// ```swift
/// final class CallViewController: UIViewController {
///     private var inAppBlock: DakInAppBlock?
///     override func viewWillAppear(_ animated: Bool) {
///         super.viewWillAppear(animated)
///         inAppBlock = Dak.blockInApp()
///     }
///     override func viewDidDisappear(_ animated: Bool) {
///         super.viewDidDisappear(animated)
///         inAppBlock = nil  // or inAppBlock?.end()
///     }
/// }
/// ```
public final class DakInAppBlock: @unchecked Sendable {
    private let onEnd: Locked<(() -> Void)?>

    init(_ onEnd: @escaping () -> Void) {
        self.onEnd = Locked(onEnd)
    }

    deinit {
        end()
    }

    /// Ends the block. Later calls do nothing; releasing the block ends it too.
    public func end() {
        onEnd.update { f -> (() -> Void)? in
            let g = f
            f = nil
            return g
        }?()
    }
}

/// Colours for in-app messages where the message sets none. Each nil takes
/// the system's: the app's tint colour (its AccentColor) for the first button,
/// and the system background and label colours, which follow dark mode.
///
/// ```swift
/// Dak.inAppTheme = DakInAppTheme(primary: UIColor(named: "Brand"))
/// ```
public struct DakInAppTheme {
    /// The first button's background; nil: the app's tint colour.
    public var primary: UIColor?
    /// The first button's text; nil: black or white, whichever reads.
    public var onPrimary: UIColor?
    /// The message's background; nil: the system background (elevated).
    public var surface: UIColor?
    /// Titles and the X; nil: the label colour.
    public var onSurface: UIColor?
    /// Text; nil: the secondary label colour.
    public var onSurfaceVariant: UIColor?

    public init(
        primary: UIColor? = nil, onPrimary: UIColor? = nil, surface: UIColor? = nil, onSurface: UIColor? = nil,
        onSurfaceVariant: UIColor? = nil
    ) {
        self.primary = primary
        self.onPrimary = onPrimary
        self.surface = surface
        self.onSurface = onSurface
        self.onSurfaceVariant = onSurfaceVariant
    }
}
