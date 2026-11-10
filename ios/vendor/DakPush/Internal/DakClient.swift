import CryptoKit
import Foundation

/// Where the client reports to the app (the facade passes them on, on the
/// main thread).
protocol DakClientEvents: AnyObject {
    /// The device has an id: the saved one once read, or a new registration.
    func deviceId(_ id: String)

    /// The server refused a change.
    func error(_ error: DakError)
}

/// The end of a change: nil when it was saved and either sent or kept to send
/// later (no network), the server's refusal otherwise.
typealias DakCallback = (DakError?) -> Void

struct DakPendingOpen: Equatable {
    let id: String
    let action: String?
}

/// hex(sha256(device secret)): what the notification service extension
/// holds. It can report deliveries and nothing else.
func receiptToken(_ secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// The SDK's logic: it keeps the state the app wants (token, user, tags,
/// permission) and the state the server last accepted, and sends the
/// difference whenever they differ. Everything is saved, so changes made
/// offline are sent on a later start.
///
/// All state lives on [scheduler]'s one queue. Calls from other threads post
/// a task there; a change made while a sync runs is sent by the next round.
final class DakClient: @unchecked Sendable {
    static let maxTags = 50
    static let maxReceipts = 200
    static let maxOpens = 50
    static let receiptBatch = 50
    /// Reads of a readable phone that may fail before the SDK starts over.
    static let loadTries = 3
    /// The longest the SDK honours a Retry-After.
    static let maxRetryAfter: TimeInterval = 3600
    static let tokenType = "apns"

    private static let plainFields = [
        "platform", "app_version", "os_version", "sdk_version",
        "language", "push_permission", "subscribed", "utc_offset_minutes",
    ]

    private let api: DakApi
    private let store: DakStateStore
    private let secrets: DakSecretStore
    private let platform: DakPlatformInfo
    private let scheduler: DakScheduler
    /// Where [DakCallback]s run: the main queue in the app.
    private let callbacks: (@escaping () -> Void) -> Void
    private weak var events: DakClientEvents?
    private let log: DakLog
    private let sdkVersion: String
    /// Send the phone's UTC offset, for local-time delivery and quiet hours.
    private let shareTimezoneOffset: Bool
    /// Shared with the notification service extension, if the app has one.
    private let appGroup: DakAppGroup?
    private let categories: DakCategoryCenter?
    private let clock: () -> Date
    private let random: () -> Double
    /// Waits between retries of a failed sync; the last one repeats. Empty:
    /// no retries (tests).
    private let retryDelays: [TimeInterval]
    private let lastSeenInterval: TimeInterval

    // Saved state.
    private var deviceId: String?
    private var secret: String?
    private var token: String?
    private var tokenType = DakClient.tokenType
    private var externalId: String?
    private var authHash: String?
    private var tags: [String: String] = [:]
    private var subscribed = true
    private var reported: [String: JSON] = [:]
    private var lastSeenSent: Date?
    private var opens: [DakPendingOpen] = []
    private var receipts: [String] = []

    // Read at start.
    private var permission = false
    private var appVersion = ""
    private var osVersion = ""
    private var language = ""
    private var offset: Int?

    private var started = false
    private var loaded = false
    private var loadFailures = 0
    private var loadAttempts = 0
    private var disposed = false

    /// What came in before the saved state was read: applied after, so the
    /// saved state cannot overwrite it.
    private var waiting: [() -> Void] = []
    private var syncQueued = false
    private var syncCallbacks: [DakCallback] = []
    private var again = false
    private var reRegistered = false
    private var failures = 0
    private var notBefore: Date?
    private var retryTimer: DakCancelable?
    private var loadTimer: DakCancelable?
    private var sharedWithExtension: String?

    /// The device id, readable from any thread; nil before the device registers.
    private let deviceIdBox = Locked<String?>(nil)
    private let credentialsBox = Locked<(deviceId: String, secret: String)?>(nil)

    var currentDeviceId: String? { deviceIdBox.value }

    /// The device's id and secret, for the SDK's other parts (in-app messages).
    var credentials: (deviceId: String, secret: String)? { credentialsBox.value }

    init(
        api: DakApi, store: DakStateStore, secrets: DakSecretStore, platform: DakPlatformInfo,
        scheduler: DakScheduler, callbacks: @escaping (@escaping () -> Void) -> Void, events: DakClientEvents,
        log: DakLog, sdkVersion: String, shareTimezoneOffset: Bool = false, appGroup: DakAppGroup? = nil,
        categories: DakCategoryCenter? = nil, clock: @escaping () -> Date = Date.init,
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        retryDelays: [TimeInterval] = [5, 15, 60, 300], lastSeenInterval: TimeInterval = 12 * 3600
    ) {
        self.api = api
        self.store = store
        self.secrets = secrets
        self.platform = platform
        self.scheduler = scheduler
        self.callbacks = callbacks
        self.events = events
        self.log = log
        self.sdkVersion = sdkVersion
        self.shareTimezoneOffset = shareTimezoneOffset
        self.appGroup = appGroup
        self.categories = categories
        self.clock = clock
        self.random = random
        self.retryDelays = retryDelays
        self.lastSeenInterval = lastSeenInterval
    }

    /// Reads the saved state and returns; the first sync follows, so a slow
    /// network never holds the app's start.
    func start() {
        scheduler.execute { [self] in
            if started || disposed { return }
            started = true
            readPlatform()
            load()
            whenLoaded { self.connect() }
        }
    }

    func login(_ externalId: String, authHash: String?, callback: DakCallback?) {
        change(callback) {
            self.externalId = externalId
            self.authHash = authHash
        }
    }

    /// Unlinks the user and removes the device's tags, so the next user of
    /// this phone starts without them. Push permission and the subscription
    /// stay.
    func logout(callback: DakCallback?) {
        change(callback) {
            self.externalId = nil
            self.authHash = nil
            self.tags = [:]
        }
    }

    /// [changes] are checked by the caller; a nil or empty value removes the tag.
    func setTags(_ changes: [String: String?], callback: DakCallback?) {
        scheduler.execute { [self] in
            whenLoaded {
                var next = self.tags
                for (k, v) in changes {
                    if let v, !v.isEmpty { next[k] = v } else { next.removeValue(forKey: k) }
                }
                if next.count > Self.maxTags {
                    let error = DakError(
                        message: "a device can have at most \(Self.maxTags) tags", code: "invalid", field: "tags")
                    if let callback { self.callbacks { callback(error) } }
                    return
                }
                self.tags = next
                self.save()
                self.requestSync(callback)
            }
        }
    }

    /// Opts this device out of (false) or back into (true) all pushes.
    func setSubscribed(_ subscribed: Bool, callback: DakCallback?) {
        change(callback) { self.subscribed = subscribed }
    }

    /// Notification permission may have changed (a prompt, system settings).
    func refreshPermission(callback: DakCallback? = nil) {
        change(callback) { self.permission = self.platform.notificationsEnabled() }
    }

    /// The APNs device token, in lower-case hex.
    func onNewToken(_ value: String) {
        scheduler.execute { [self] in
            whenLoaded {
                if self.token == value && self.tokenType == Self.tokenType {
                    // Every start hands the same token: nothing new to save.
                    self.requestSync(nil)
                    return
                }
                self.token = value
                self.tokenType = Self.tokenType
                self.log.d("dak: new APNs token")
                self.save()
                self.requestSync(nil)
            }
        }
    }

    /// A tap on a notification, or on its button [action].
    func addOpen(_ messageId: String, action: String?) {
        scheduler.execute { [self] in
            whenLoaded {
                if self.opens.contains(where: { $0.id == messageId }) { return }
                self.opens.append(DakPendingOpen(id: messageId, action: action))
                if self.opens.count > Self.maxOpens { self.opens = Array(self.opens.suffix(Self.maxOpens)) }
                self.save()
                self.requestSync(nil)
            }
        }
    }

    /// A push that arrived (shown in the foreground, or silent).
    func addReceipt(_ messageId: String, callback: DakCallback? = nil) {
        scheduler.execute { [self] in
            whenLoaded {
                if !self.receipts.contains(messageId) {
                    self.receipts.append(messageId)
                    if self.receipts.count > Self.maxReceipts {
                        self.receipts = Array(self.receipts.suffix(Self.maxReceipts))
                    }
                    self.save()
                }
                self.requestSync(callback)
            }
        }
    }

    /// The app came to the foreground: picks up permission changes made in
    /// system settings, receipts the extension kept, a new UTC offset, and
    /// keeps last_seen fresh. Also tries again to read a state the locked
    /// phone kept closed.
    func onResume() {
        scheduler.execute { [self] in
            if !started || disposed { return }
            load()
            whenLoaded {
                self.permission = self.orElse(self.permission, "permission") { self.platform.notificationsEnabled() }
                if self.shareTimezoneOffset {
                    self.offset = self.orElse(self.offset, "UTC offset") { self.platform.utcOffsetMinutes() }
                }
                self.collectPending()
                self.requestSync(nil)
            }
        }
    }

    /// The phone was unlocked: the saved state can be read now.
    func retryLoad() {
        scheduler.execute { [self] in
            if started && !disposed { load() }
        }
    }

    /// Sends anything pending now.
    func flush(callback: DakCallback? = nil) {
        scheduler.execute { [self] in
            whenLoaded {
                self.collectPending()
                self.requestSync(callback)
            }
        }
    }

    func dispose() {
        scheduler.execute { [self] in
            disposed = true
            retryTimer?.cancel()
            loadTimer?.cancel()
        }
    }

    private func change(_ callback: DakCallback?, _ apply: @escaping () -> Void) {
        scheduler.execute { [self] in
            whenLoaded {
                apply()
                self.save()
                self.requestSync(callback)
            }
        }
    }

    /// The network half of [start].
    private func connect() {
        collectPending()
        save()
        requestSync(nil)
    }

    /// Each detail on its own. Versions are cut to the server's 32 bytes.
    private func readPlatform() {
        appVersion = clampUtf8(platform.appVersion(), 32)
        osVersion = clampUtf8(platform.osVersion(), 32)
        language = platform.language()
        offset = shareTimezoneOffset ? platform.utcOffsetMinutes() : nil
        permission = platform.notificationsEnabled()
    }

    private func orElse<T>(_ fallback: T, _ what: String, _ read: () throws -> T) -> T {
        do {
            return try read()
        } catch {
            log.d("dak: could not read the \(what): \(error)")
            return fallback
        }
    }

    private func whenLoaded(_ task: @escaping () -> Void) {
        if loaded { task() } else { waiting.append(task) }
    }

    /// Adds the receipts the extension kept, saves, and only then deletes them
    /// there, so a crash in between loses nothing. Also puts back the
    /// extension's button categories if something replaced them.
    private func collectPending() {
        guard let group = appGroup else { return }
        if let categories { DakCategories.restore(center: categories, group: group) }
        let kept = group.keptReceipts
        if kept.isEmpty { return }
        for id in kept where !receipts.contains(id) { receipts.append(id) }
        if receipts.count > Self.maxReceipts { receipts = Array(receipts.suffix(Self.maxReceipts)) }
        if save() { group.removeReceipts(kept) }
    }

    // MARK: - Sync

    private func desired() -> [String: JSON] {
        [
            "token": JSON(token),
            "token_type": .string(tokenType),
            "platform": .string("ios"),
            "app_version": .string(appVersion),
            "os_version": .string(osVersion),
            "sdk_version": .string(sdkVersion),
            "language": .string(language),
            "push_permission": .bool(permission),
            "subscribed": .bool(subscribed),
            "external_id": JSON(externalId),
            "utc_offset_minutes": JSON(offset),
            "tags": JSON(tags),
        ]
    }

    /// Runs a sync after the tasks already queued, so changes made together go
    /// in one round; every caller hears the result of the round that includes
    /// its change.
    private func requestSync(_ callback: DakCallback?) {
        if let callback { syncCallbacks.append(callback) }
        if syncQueued { return }
        syncQueued = true
        scheduler.execute { [self] in
            syncQueued = false
            let waitingCallbacks = syncCallbacks
            syncCallbacks = []
            let refused = runSync()
            for c in waitingCallbacks { callbacks { c(refused) } }
        }
    }

    /// One round. While the server's Retry-After lasts, changes are only saved.
    private func runSync() -> DakError? {
        if disposed || !loaded { return nil }
        if let wait = notBefore, clock() < wait {
            if retryTimer == nil { retryAt(wait.timeIntervalSince(clock())) }
            return nil
        }
        notBefore = nil
        var refused: DakError?
        var reverted = Set<String>()
        reRegistered = false
        again = true
        while again && !disposed {
            again = false
            do {
                try syncOnce()
                shareWithExtension()
                try sendOpens()
                try sendReceipts()
                failures = 0
                retryTimer?.cancel()
                retryTimer = nil
            } catch let e as DakApiError {
                if !e.isPermanent {
                    log.d("dak: sync failed, will retry: \(e)")
                    scheduleRetry(e.retryAfter)
                    break
                }
                let error = DakError(message: e.message.isEmpty ? e.code : e.message, code: e.code, field: e.field, status: e.status)
                if refused == nil { refused = error }
                log.w("dak: the server refused a change: \(error)")
                events?.error(error)
                // The server refused something the app set (a wrong auth hash,
                // a bad tag): go back to what it last accepted for that field
                // alone, so the rest (an opt-out above all) still gets through.
                guard let field = Self.revertible(e), reverted.insert(field).inserted else { break }
                revert(field)
                save()
                again = true
            } catch {
                log.d("dak: sync failed, will retry: \(error)")
                scheduleRetry(nil)
                break
            }
        }
        return refused
    }

    /// The app-set field a refusal is about, if it can be rolled back.
    /// `subscribed` never is: the user's choice stays.
    static func revertible(_ e: DakApiError) -> String? {
        if e.code == "identity_verification_failed" { return "external_id" }
        switch e.field {
        case "external_id", "auth_hash": return "external_id"
        case "tags": return "tags"
        default: return nil
        }
    }

    private func revert(_ field: String) {
        switch field {
        case "external_id":
            externalId = reported["external_id"]?.string
            if externalId == nil { authHash = nil }
        case "tags":
            tags = reported["tags"]?.stringMap ?? [:]
        default:
            break
        }
    }

    private func scheduleRetry(_ retryAfter: TimeInterval?) {
        if disposed || retryDelays.isEmpty { return }
        let delay = retryDelay(failures: failures, retryAfter: retryAfter)
        failures += 1
        if retryAfter != nil { notBefore = clock().addingTimeInterval(delay) }
        retryAt(delay)
    }

    private func retryAt(_ delay: TimeInterval) {
        retryTimer?.cancel()
        if disposed { return }
        retryTimer = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            self.notBefore = nil
            self.requestSync(nil)
        }
    }

    /// The wait before retry number [failures] + 1: the step from
    /// [retryDelays], of which a random half, so phones that failed together
    /// do not come back together; never shorter than the server's Retry-After
    /// (up to an hour).
    func retryDelay(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let step = retryDelays[min(failures, retryDelays.count - 1)]
        let jittered = step * (0.5 + 0.5 * random())
        guard let retryAfter else { return jittered }
        return max(min(retryAfter, Self.maxRetryAfter), jittered)
    }

    private func syncOnce() throws {
        let desired = desired()
        guard let token else { return }  // nothing to register until APNs gives a token
        guard let id = deviceId, let sec = secret else {
            // The whole state, nulls included: the server may hand over an old
            // row for this token, whose user and offset must not stay.
            var body = desired
            if externalId != nil, let authHash { body["auth_hash"] = .string(authHash) }
            let reg = try api.register(body)
            deviceId = reg.deviceId
            secret = reg.deviceSecret
            reported = desired
            lastSeenSent = clock()
            do {
                try secrets.write(DakDeviceSecret(deviceId: reg.deviceId, secret: reg.deviceSecret))
            } catch {
                // Kept in memory; the next start registers again.
                log.w("dak: could not save the device secret: \(error)")
            }
            save()
            publishDeviceId()
            log.d("dak: registered as \(reg.deviceId)")
            return
        }

        var patch: [String: JSON] = [:]
        // A token always goes with its type, which the server would otherwise
        // reset to "token".
        if .string(token) != reported["token"] || .string(tokenType) != (reported["token_type"] ?? .string("token")) {
            patch["token"] = .string(token)
            patch["token_type"] = .string(tokenType)
        }
        for f in Self.plainFields where desired[f] != reported[f] { patch[f] = desired[f] ?? .null }
        if JSON(externalId) != reported["external_id"] ?? .null {
            patch["external_id"] = JSON(externalId)
            if externalId != nil, let authHash { patch["auth_hash"] = .string(authHash) }
        }
        let had = reported["tags"]?.stringMap ?? [:]
        var tagChanges: [String: JSON] = [:]
        for (k, v) in tags where had[k] != v { tagChanges[k] = .string(v) }
        for k in had.keys where tags[k] == nil { tagChanges[k] = .null }
        if !tagChanges.isEmpty { patch["tags"] = .object(tagChanges) }

        let stale = lastSeenSent.map { clock().timeIntervalSince($0) >= lastSeenInterval } ?? true
        if patch.isEmpty && !stale { return }
        do {
            try api.update(deviceId: id, secret: sec, patch)
        } catch let e as DakApiError where e.isUnauthorized && !reRegistered {
            // The server no longer knows this device (deleted after a dead
            // token or a long absence): register again with the full state.
            forgetDevice()
            return
        }
        reported = desired
        lastSeenSent = clock()
        save()
    }

    /// Drops the id and secret, so the next round registers again. Once per
    /// sync, so a server that keeps refusing cannot loop it.
    private func forgetDevice() {
        log.d("dak: the server does not know this device any more; registering again")
        deviceId = nil
        secret = nil
        deviceIdBox.value = nil
        credentialsBox.value = nil
        reported = [:]
        reRegistered = true
        sharedWithExtension = nil
        appGroup?.removeConfig()
        do { try secrets.delete() } catch { log.d("dak: could not delete the device secret: \(error)") }
        save()
        again = true
    }

    /// Gives the notification service extension what it needs to report
    /// deliveries: only the receipt token, never the device secret.
    private func shareWithExtension() {
        guard let group = appGroup, let id = deviceId, let sec = secret else { return }
        let key = "\(id):\(sec)"
        if sharedWithExtension == key { return }
        group.share(
            DakAppGroup.Config(baseURL: api.baseURL, appId: api.appId, deviceId: id, receiptToken: receiptToken(sec)))
        sharedWithExtension = key
    }

    /// A 401 means the device must register again; the open is kept for the
    /// new registration.
    private func sendOpens() throws {
        while let o = opens.first {
            guard let id = deviceId, let sec = secret else { return }
            do {
                try api.opened(deviceId: id, secret: sec, messageId: o.id, actionId: o.action)
            } catch let e as DakApiError {
                if e.isUnauthorized && !reRegistered { return forgetDevice() }
                if !e.isPermanent && !e.isUnauthorized { throw e }
            }
            opens.removeFirst()
            save()
        }
    }

    private func sendReceipts() throws {
        while !receipts.isEmpty {
            guard let id = deviceId, let sec = secret else { return }
            let batch = Array(receipts.prefix(Self.receiptBatch))
            do {
                try api.delivered(deviceId: id, secret: sec, messageIds: batch)
            } catch let e as DakApiError {
                if e.isUnauthorized && !reRegistered { return forgetDevice() }
                if !e.isPermanent && !e.isUnauthorized { throw e }
            }
            receipts.removeFirst(batch.count)
            save()
        }
    }

    private func publishDeviceId() {
        guard let id = deviceId else { return }
        deviceIdBox.value = id
        credentialsBox.value = secret.map { (id, $0) }
        events?.deviceId(id)
    }

    // MARK: - Persistence

    /// Reads the saved state. A read that fails is tried again later, and
    /// nothing is saved or sent until one works, so the stored state is never
    /// replaced by an empty one. A locked phone is waited for as long as it
    /// takes; on an unlocked phone the SDK starts over after a few tries.
    private func load() {
        if loaded || disposed { return }
        loadTimer?.cancel()
        loadTimer = nil
        let raw: Data?
        do {
            raw = try store.read()
        } catch {
            return loadFailed(error)
        }
        let state = raw.flatMap(JSON.decodeObject)
        if raw != nil && state == nil { log.w("dak: ignoring unreadable saved state") }
        var saved: DakDeviceSecret?
        if let state, state["app_id"]?.string == api.appId, let id = state["device_id"]?.string {
            do {
                saved = try secrets.read()
            } catch let e as DakStoreUnavailable {
                return loadFailed(e)
            } catch {
                log.w("dak: the device secret cannot be read; registering again: \(error)")
            }
            if saved != nil && saved?.deviceId != id { saved = nil }
            if saved == nil { log.d("dak: no device secret for the saved device; registering again") }
        }
        restore(state, saved)
        loadedNow()
    }

    private func loadFailed(_ error: Error) {
        let locked = error is DakStoreUnavailable || !platform.protectedDataAvailable
        if !locked {
            loadFailures += 1
            if loadFailures >= Self.loadTries || retryDelays.isEmpty {
                log.w("dak: the saved state cannot be read; starting over: \(error)")
                return loadedNow()
            }
        }
        log.d("dak: saved state not readable yet, will try again: \(error)")
        guard !retryDelays.isEmpty else { return }
        let delay = retryDelays[min(loadAttempts, retryDelays.count - 1)]
        loadAttempts += 1
        loadTimer = scheduler.schedule(after: delay) { [weak self] in self?.load() }
    }

    private func loadedNow() {
        loaded = true
        if deviceId != nil { publishDeviceId() }  // the saved one, for listeners from before the load
        while !waiting.isEmpty { waiting.removeFirst()() }
    }

    private func restore(_ js: [String: JSON]?, _ saved: DakDeviceSecret?) {
        guard let js else { return }
        externalId = js["external_id"]?.string
        authHash = js["auth_hash"]?.string
        tags = js["tags"]?.stringMap ?? [:]
        subscribed = js["subscribed"]?.bool ?? true
        token = js["token"]?.string
        tokenType = js["token_type"]?.string ?? Self.tokenType
        guard js["app_id"]?.string == api.appId else {
            // Another Dak app: its device is not this app's. The user's choices stay.
            log.d("dak: the saved device belongs to another app id; registering again")
            return
        }
        opens = (js["opens"]?.array ?? []).compactMap { o in
            o.object?["id"]?.string.map { DakPendingOpen(id: $0, action: o.object?["action"]?.string) }
        }
        receipts = (js["receipts"]?.array ?? []).compactMap(\.string)
        guard let saved, js["device_id"]?.string == saved.deviceId else { return }
        deviceId = saved.deviceId
        secret = saved.secret
        reported = js["reported"]?.object ?? [:]
        lastSeenSent = js["last_seen_sent"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Saving can fail (a full disk, a locked phone); the state then lives in
    /// memory until the next save works.
    @discardableResult
    private func save() -> Bool {
        if !loaded { return false }
        do {
            try store.write(encode())
            return true
        } catch {
            log.w("dak: could not save the state: \(error)")
            return false
        }
    }

    private func encode() -> Data {
        var js: [String: JSON] = [
            "v": .int(1),
            "base_url": .string(api.baseURL),
            "app_id": .string(api.appId),
            "device_id": JSON(deviceId),
            "token": JSON(token),
            "token_type": .string(tokenType),
            "external_id": JSON(externalId),
            "auth_hash": JSON(authHash),
            "tags": JSON(tags),
            "subscribed": .bool(subscribed),
            "reported": .object(reported),
            "opens": .array(opens.map { .object(["id": .string($0.id), "action": JSON($0.action)]) }),
            "receipts": .array(receipts.map { .string($0) }),
        ]
        if let lastSeenSent { js["last_seen_sent"] = .int(Int(lastSeenSent.timeIntervalSince1970 * 1000)) }
        return JSON.encode(js)
    }
}
