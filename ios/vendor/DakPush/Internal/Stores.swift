import Foundation
import Security

/// A store that cannot be read or written yet: the iPhone has not been
/// unlocked since it started (an app woken by a push then). The SDK tries
/// again later and never writes over what it could not read.
struct DakStoreUnavailable: Error, CustomStringConvertible {
    let description: String
}

/// The SDK's state between app starts (one small JSON document), without the
/// device secret.
protocol DakStateStore: AnyObject {
    /// Nil when nothing is saved; throws when it cannot be read.
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// The device secret, with the id of the device it belongs to.
struct DakDeviceSecret: Equatable {
    let deviceId: String
    let secret: String
}

/// Where the device secret is kept: the keychain.
protocol DakSecretStore: AnyObject {
    /// Nil when there is none; throws [DakStoreUnavailable] on a locked phone.
    func read() throws -> DakDeviceSecret?
    func write(_ secret: DakDeviceSecret) throws
    func delete() throws
}

/// The state in a file in Application Support/DakPush: deleted with the app,
/// kept out of backups (a restored backup must not bring another phone's
/// device along), and readable after the first unlock since the phone
/// started, so a push that wakes the app on a locked phone can still read it.
final class FileStateStore: DakStateStore {
    let url: URL
    private var prepared = false

    init(url: URL) {
        self.url = url
    }

    /// Application Support/DakPush/[name]: state.json for the client,
    /// in_app.json for in-app messages.
    static func standard(_ name: String = "state.json") -> FileStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileStateStore(url: base.appendingPathComponent("DakPush/\(name)"))
    }

    /// The folder, made on the first write, out of backups.
    private func prepare() throws {
        if prepared { return }
        var dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        prepared = true
    }

    func read() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw DakStoreUnavailable(description: "the state file cannot be read before the first unlock: \(error)")
        }
    }

    /// A temporary file, then a rename: a crash never leaves half a state.
    func write(_ data: Data) throws {
        do {
            try prepare()
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            throw DakStoreUnavailable(description: "the state file cannot be written before the first unlock: \(error)")
        }
    }
}

/// The device secret in the keychain, readable after the first unlock since
/// the phone started and on this device only: a backup restored on another
/// phone does not bring it along.
final class KeychainSecretStore: DakSecretStore {
    let service: String
    private let account: String

    init(service: String = "dakpush", account: String = "device") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() throws -> DakDeviceSecret? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, let js = JSON.decodeObject(data),
                let id = js["device_id"]?.string, let secret = js["secret"]?.string
            else { return nil }
            return DakDeviceSecret(deviceId: id, secret: secret)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw DakStoreUnavailable(description: "the keychain is locked")
        default:
            throw KeychainError(status: status)
        }
    }

    func write(_ secret: DakDeviceSecret) throws {
        let data = JSON.encode(["device_id": .string(secret.deviceId), "secret": .string(secret.secret)])
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecInteractionNotAllowed { throw DakStoreUnavailable(description: "the keychain is locked") }
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status) }
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return "keychain error \(status) \(text)"
        }
    }
}
