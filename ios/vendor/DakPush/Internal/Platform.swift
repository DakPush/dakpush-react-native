import Foundation
import UserNotifications

/// Facts about the install the server uses for targeting. Nothing that
/// identifies the person or the phone: no model, no IP, no location (the UTC
/// offset only if the app opts in).
protocol DakPlatformInfo: AnyObject {
    /// `<CFBundleShortVersionString>+<CFBundleVersion>`, like "8.0.2+535".
    func appVersion() -> String
    func osVersion() -> String
    /// The language code ("bn", "en"), as the server matches translations.
    func language() -> String
    /// The phone's UTC offset in minutes right now (+360 in Bangladesh).
    func utcOffsetMinutes() -> Int
    /// Whether the user allows this app's notifications (provisional and
    /// ephemeral count). Waits for iOS, at most two seconds.
    func notificationsEnabled() -> Bool
    /// False until the first unlock since the phone started: the state and
    /// the keychain cannot be read then.
    var protectedDataAvailable: Bool { get }
}

final class IOSPlatformInfo: DakPlatformInfo {
    /// Kept by the facade from UIApplication's notifications.
    let protectedData: Locked<Bool>
    private let bundle: Bundle

    init(protectedData: Locked<Bool>, bundle: Bundle = .main) {
        self.protectedData = protectedData
        self.bundle = bundle
    }

    func appVersion() -> String {
        Self.appVersion(
            short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    static func appVersion(short: String?, build: String?) -> String {
        let name = short ?? ""
        let code = build ?? ""
        if code.isEmpty { return name }
        return name.isEmpty ? code : "\(name)+\(code)"
    }

    /// Like UIDevice's systemVersion: "26.1", "17.4.1".
    func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    func language() -> String {
        Self.languageCode(Locale.preferredLanguages.first ?? "")
    }

    /// "bn-BD" → "bn"; "" when it is not a language code.
    static func languageCode(_ identifier: String) -> String {
        let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
        let letters = code.unicodeScalars.allSatisfy { $0.value >= 0x61 && $0.value <= 0x7a }
        return (2...3).contains(code.count) && letters && code != "und" ? code : ""
    }

    func utcOffsetMinutes() -> Int {
        TimeZone.current.secondsFromGMT() / 60
    }

    func notificationsEnabled() -> Bool {
        let done = DispatchSemaphore(value: 0)
        let allowed = Locked(false)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            allowed.value = Self.allows(settings.authorizationStatus)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return allowed.value
    }

    static func allows(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    var protectedDataAvailable: Bool { protectedData.value }
}
