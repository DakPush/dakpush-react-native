import Foundation

/// The device's id and secret, which the in-app calls to the server need.
typealias DakCredentials = (deviceId: String, secret: String)

/// The in-app message logic, a port of the Flutter SDK's
/// lib/src/in_app/controller.dart: keeps the server's list (also offline),
/// counts sessions, checks triggers and frequency, picks what to show, and
/// reports impressions, clicks and dismissals. The presenter draws
/// ``current`` and reports back with ``didDisplay(_:)`` or ``didFail(_:)``.
///
/// Everything runs on [home] (the main queue in the app): the presenter and
/// the facade call it there. Network and disk run on [io] and come back to
/// [home]. Tests pass one TestScheduler as both.
final class InAppController {
    /// What the phone remembers about a message.
    struct Local: Equatable {
        var shown = 0
        var last: Date?
        /// The session it was last shown in (for every_session).
        var session = 0
        /// Hidden by a pause, a block or a scene going away before the user
        /// closed it: it comes back once, and that is not a new impression.
        var interrupted = false

        var json: JSON {
            var o: [String: JSON] = ["shown": .int(shown), "session": .int(session)]
            if let last { o["last"] = .int(InAppController.millis(last)) }
            if interrupted { o["interrupted"] = .bool(true) }
            return .object(o)
        }

        init(shown: Int = 0, last: Date? = nil, session: Int = 0, interrupted: Bool = false) {
            self.shown = shown
            self.last = last
            self.session = session
            self.interrupted = interrupted
        }

        init?(json: JSON) {
            guard let o = json.object else { return nil }
            shown = o["shown"]?.int ?? 0
            last = InAppController.date(o["last"])
            session = o["session"]?.int ?? 0
            interrupted = o["interrupted"]?.bool ?? false
        }
    }

    /// An impression, click or dismissal waiting to be sent.
    struct Event: Equatable {
        let messageId: String
        /// impression | click | dismiss
        let type: String
        let buttonId: String?
        /// Grows with every event of the device: the server skips resends.
        let seq: Int
        /// When it happened, as the server reads it.
        let at: String

        var json: JSON {
            var o: [String: JSON] = [
                "message_id": .string(messageId), "type": .string(type), "seq": .int(seq), "at": .string(at),
            ]
            if let buttonId { o["button_id"] = .string(buttonId) }
            return .object(o)
        }

        init(messageId: String, type: String, buttonId: String?, seq: Int, at: String) {
            self.messageId = messageId
            self.type = type
            self.buttonId = buttonId
            self.seq = seq
            self.at = at
        }

        init?(json: JSON) {
            guard let o = json.object, let id = o["message_id"]?.string, let type = o["type"]?.string,
                let seq = o["seq"]?.int, let at = o["at"]?.string
            else { return nil }
            self.init(messageId: id, type: type, buttonId: o["button_id"]?.string, seq: seq, at: at)
        }
    }

    static let maxEvents = 500
    static let eventBatch = 100
    static let maxLocal = 500
    /// Time triggers further away than this are checked at the next event.
    static let maxTimer: TimeInterval = 24 * 3600

    private let api: DakApi
    private let store: DakStateStore
    private let credentials: () -> DakCredentials?
    private let setTags: ([String: String]) -> Void
    private let openURL: ((URL) -> Void)?
    private let urlSchemes: Set<String>
    private let home: DakScheduler
    private let io: DakScheduler
    private let clock: () -> Date
    private let log: DakLog
    /// The app is in the foreground now; nil (tests) counts as yes.
    private let isForeground: (() -> Bool)?

    /// Without a successful fetch for this long, the cached list is not
    /// shown: the server may have stopped those messages since.
    let cacheMaxAge: TimeInterval
    /// Back from the background after this long starts a new session.
    let sessionTimeout: TimeInterval
    /// How long a session start waits for the server before using the cache.
    let fetchWait: TimeInterval
    /// Session starts closer together than this use the list already fetched.
    let minFetchInterval: TimeInterval
    /// Events are sent this long after the last one; nil sends them only on
    /// [flushEvents] (tests).
    let eventDelay: TimeInterval?

    /// ``current`` or ``activeHost`` changed. Runs on [home].
    var onChange: (() -> Void)?
    /// A click, after it was counted. Runs on [home].
    var onClick: ((DakInAppClick) -> Void)?

    // Saved.
    private var raw: [JSON] = []
    private var etag: String?
    private var fetchedAt: Date?
    /// The device the list and its ETag were fetched for.
    private var fetchedFor: String?
    private var local: [String: Local] = [:]
    private(set) var sessionCount = 0
    private var installedAt: Date?
    private var events: [Event] = []
    private var seq = 0

    // This run.
    private(set) var messages: [InAppMessage] = []
    private(set) var triggers: [String: InAppTrigger] = [:]
    private var sessionStart: Date
    private var backgroundAt: Date?
    private var started = false
    /// The saved state was read (or could not be); until then nothing shows.
    private var ready = false
    /// The saved state was read (or was unreadable data); until then nothing
    /// is saved over it.
    private var canSave = false
    private var reloading = false
    private var foreground = true
    /// Started in the background: the first session waits for the foreground.
    private var sessionDue = false
    private var paused = false
    private var blocks = 0
    private var hosts: [AnyHashable] = []
    private var pending = false
    private var displayed = false
    private var failed = Set<String>()
    private var timer: DakCancelable?
    private var eventTimer: DakCancelable?
    private var fetching = false
    private var fetchWaiters: [() -> Void] = []
    private var sending = false
    private var sendWaiters: [() -> Void] = []
    private var disposed = false
    private let pausedBox = Locked(false)

    /// The message to show now, or nil.
    private(set) var current: InAppMessage? {
        didSet { if oldValue != current { onChange?() } }
    }

    /// The host (a window scene) that draws ``current``: the first attached
    /// one, so two never show the same message.
    private(set) var activeHost: AnyHashable? {
        didSet { if oldValue != activeHost { onChange?() } }
    }

    /// When a time trigger (session_time, since_install) next comes true.
    private(set) var nextTimeCheck: Date?

    init(
        api: DakApi, store: DakStateStore, credentials: @escaping () -> DakCredentials?,
        setTags: @escaping ([String: String]) -> Void, openURL: ((URL) -> Void)?,
        urlSchemes: Set<String> = ["https", "http"], home: DakScheduler, io: DakScheduler, clock: @escaping () -> Date,
        log: DakLog, isForeground: (() -> Bool)? = nil, cacheMaxAge: TimeInterval = 7 * 86400,
        sessionTimeout: TimeInterval = 300, fetchWait: TimeInterval = 3, minFetchInterval: TimeInterval = 60,
        eventDelay: TimeInterval? = 2
    ) {
        self.api = api
        self.store = store
        self.credentials = credentials
        self.setTags = setTags
        self.openURL = openURL
        self.urlSchemes = Set(urlSchemes.map { $0.lowercased() })
        self.home = home
        self.io = io
        self.clock = clock
        self.log = log
        self.isForeground = isForeground
        self.cacheMaxAge = cacheMaxAge
        self.sessionTimeout = sessionTimeout
        self.fetchWait = fetchWait
        self.minFetchInterval = minFetchInterval
        self.eventDelay = eventDelay
        sessionStart = clock()
    }

    /// A message is on screen (drawn).
    var isShowing: Bool { current != nil && displayed }

    /// Paused by [setPaused] or a [block]. Readable from any thread.
    var isPaused: Bool { pausedBox.value }

    /// Impressions, clicks and dismissals waiting to be sent.
    var pendingEvents: Int { events.count }

    // MARK: - Start and fetch

    /// Reads the saved state, then starts the first session and fetches the
    /// list. An app launched in the background (a push, a background fetch)
    /// starts its first session when it comes to the foreground.
    func start() {
        if started { return }
        started = true
        let store = self.store
        io.execute { [weak self] in
            let result = Result { try store.read() }
            self?.home.execute { self?.loaded(result) }
        }
    }

    private func loaded(_ result: Result<Data?, Error>) {
        if disposed { return }
        switch result {
        case .success(let data):
            canSave = true
            restore(data)
        case .failure(let error):
            log.d("dak: in-app state not readable yet, running from memory: \(error)")
        }
        ready = true
        if installedAt == nil { installedAt = clock() }
        foreground = isForeground?() ?? true
        backgroundAt = nil
        if !foreground {
            sessionDue = true
            save()
            return
        }
        newSession()
        save()
        sessionStarted()
    }

    private func newSession() {
        sessionCount += 1
        sessionStart = clock()
        failed.removeAll()
    }

    /// Fetches, and shows from the cache if the server takes longer than
    /// [fetchWait]; the fresh list is checked when it comes.
    private func sessionStarted() {
        var done = false
        let wait = home.schedule(after: fetchWait) { [weak self] in
            if !done { self?.evaluate() }
        }
        refresh { [weak self] in
            done = true
            wait.cancel()
            self?.evaluate()
            self?.flushEvents()
        }
    }

    /// Fetches the list from the server, at most once a minute unless
    /// [force]. Never fails: without a network the cache stays.
    func refresh(force: Bool = false, completion: (() -> Void)? = nil) {
        let done = completion ?? {}
        guard let c = credentials() else { return done() }
        let now = clock()
        if !force, fetchedFor == c.deviceId, let last = fetchedAt, now >= last,
            now.timeIntervalSince(last) < minFetchInterval
        {
            if fetching { fetchWaiters.append(done) } else { done() }
            return
        }
        fetchWaiters.append(done)
        if fetching { return }
        fetching = true
        let etag = fetchedFor == c.deviceId ? self.etag : nil
        let api = self.api
        io.execute { [weak self] in
            let result = Result { try api.fetchInApp(deviceId: c.deviceId, secret: c.secret, etag: etag) }
            self?.home.execute { self?.fetched(result, for: c.deviceId) }
        }
    }

    private func fetched(_ result: Result<DakInAppList?, Error>, for deviceId: String) {
        switch result {
        case .success(let list):
            if let list {
                raw = list.messages.map(JSON.init(any:))
                etag = list.etag
                messages = parse(raw)
            }
            fetchedAt = clock()
            fetchedFor = deviceId
            save()
        case .failure(let error):
            log.d("dak: in-app fetch failed, using the cache: \(error)")
        }
        fetching = false
        let waiters = fetchWaiters
        fetchWaiters = []
        for w in waiters { w() }
    }

    /// The device has an id (read at start, or a new registration): fetch its
    /// list if it is not the one already fetched.
    func onRegistered() {
        guard ready, !disposed, let c = credentials() else { return }
        refresh(force: fetchedFor != c.deviceId) { [weak self] in
            self?.evaluate()
            self?.flushEvents()
        }
    }

    /// The messages this SDK can show, best first. One it cannot read is
    /// skipped, never the whole list.
    private func parse(_ raw: [JSON]) -> [InAppMessage] {
        var list: [InAppMessage] = []
        for js in raw {
            if let m = InAppMessage.parse(js) {
                list.append(m)
            } else {
                log.d("dak: skipping an in-app message this SDK version cannot show")
            }
        }
        // Highest priority first; ties keep the server's order (newest first).
        return list.enumerated().sorted { a, b in
            a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Triggers and pause

    /// Triggers live in memory only and never leave the phone. Keys are
    /// checked by the caller.
    func addTriggers(_ values: [String: InAppTrigger]) {
        triggers.merge(values) { _, new in new }
        evaluate(queue: true)
    }

    func removeTriggers(_ keys: [String]) {
        for k in keys { triggers.removeValue(forKey: k) }
        evaluate(queue: true)
    }

    func clearTriggers() {
        removeTriggers(Array(triggers.keys))
    }

    /// Checks the triggers again now (also what the timers do).
    func check() {
        evaluate(queue: true)
    }

    /// While paused nothing shows; a message on screen is hidden (not counted
    /// as dismissed). Unpausing shows what is due.
    func setPaused(_ value: Bool) {
        paused = value
        pauseChanged()
    }

    /// Pauses until [unblock]; counted, so nested blocks work.
    func block() {
        blocks += 1
        pauseChanged()
    }

    func unblock() {
        blocks = max(0, blocks - 1)
        pauseChanged()
    }

    private func pauseChanged() {
        let now = paused || blocks > 0
        pausedBox.value = now
        if now { interrupt() } else { evaluate() }
    }

    /// Takes the message off screen without the user closing it.
    private func interrupt() {
        guard let m = current else { return }
        if displayed {
            local[m.id, default: Local()].interrupted = true
            save()
        }
        displayed = false
        current = nil
    }

    // MARK: - Hosts (window scenes)

    /// A host can draw. Hosts are counted: messages show while at least one
    /// is attached, drawn by ``activeHost``.
    func attach(_ host: AnyHashable) {
        if !hosts.contains(host) { hosts.append(host) }
        activeHost = hosts.first
        evaluate()
    }

    /// A host went away. If it was drawing, the message is hidden and the
    /// next host takes over.
    func detach(_ host: AnyHashable) {
        let wasActive = hosts.first == host
        guard let i = hosts.firstIndex(of: host) else { return }
        hosts.remove(at: i)
        guard wasActive else { return }
        interrupt()
        activeHost = hosts.first
        evaluate()
    }

    /// The user turned to [host] (the scene became active): the next message
    /// shows there. A message already chosen stays where it is.
    func prefer(_ host: AnyHashable) {
        guard current == nil, hosts.first != host else { return }
        hosts.removeAll { $0 == host }
        hosts.insert(host, at: 0)
        activeHost = host
        evaluate()
    }

    /// The presenter drew the message: count the impression.
    func didDisplay(_ m: InAppMessage) {
        guard current?.id == m.id, !displayed else { return }
        displayed = true
        var l = local[m.id] ?? Local()
        l.session = sessionCount
        if l.interrupted {
            // The same display, back after a pause: counted already.
            l.interrupted = false
            local[m.id] = l
            save()
            return
        }
        l.shown += 1
        l.last = clock()
        local[m.id] = l
        if local.count > Self.maxLocal,
            let oldest = local.min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) })
        {
            local.removeValue(forKey: oldest.key)
        }
        queueEvent(m.id, "impression")
    }

    /// The presenter could not draw it (an image-only message whose image did
    /// not load): skip it for this session.
    func didFail(_ m: InAppMessage) {
        guard current?.id == m.id else { return }
        failed.insert(m.id)
        close()
        evaluate()
    }

    /// A tap on a button, or on the message itself ([button] nil).
    func click(_ m: InAppMessage, button: InAppButton? = nil) {
        guard let action = button?.action ?? m.content.clickAction, current?.id == m.id else { return }
        queueEvent(m.id, "click", buttonId: button?.id)
        close()
        onClick?(
            DakInAppClick(
                messageId: m.id, buttonId: button?.id, actionType: action.type, url: action.url, tags: action.tags))
        switch action.type {
        case .tags:
            setTags(action.tags)
        case .url:
            guard let text = action.url, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                urlSchemes.contains(scheme)
            else {
                log.w("DakPush: not opening \(action.url ?? "") from an in-app message: only \(urlSchemes.sorted().joined(separator: ", ")) URLs are opened")
                return
            }
            openURL?(url)
        case .deepLink, .dismiss, .custom:
            break
        }
    }

    /// Closed by the X, a tap outside, a swipe, Escape or a timeout.
    func dismiss(_ m: InAppMessage) {
        guard current?.id == m.id else { return }
        if displayed { queueEvent(m.id, "dismiss") }
        close()
    }

    private func close() {
        displayed = false
        current = nil
        if pending {
            pending = false
            evaluate()
        }
    }

    // MARK: - Lifecycle

    /// The app went to the background (false) or came back (true). Going
    /// sends pending events; coming back after [sessionTimeout] starts a new
    /// session.
    func lifecycle(foreground now: Bool) {
        if !now {
            foreground = false
            if backgroundAt == nil { backgroundAt = clock() }
            if ready { flushEvents() }
            return
        }
        foreground = true
        guard ready else { return }
        if !canSave { reload() }
        let since = backgroundAt
        backgroundAt = nil
        if sessionDue || since.map({ clock().timeIntervalSince($0) >= sessionTimeout }) == true {
            sessionDue = false
            newSession()
            save()
            sessionStarted()
        } else {
            evaluate()
        }
    }

    /// The phone was unlocked: a state that could not be read can be now.
    func retryLoad() {
        if ready && !canSave { reload() }
    }

    // MARK: - Choosing

    /// Shows the best message that is due. With [queue], a message due while
    /// another is on screen follows when that one closes.
    private func evaluate(queue: Bool = false) {
        guard ready, !disposed else { return }
        let now = clock()
        scheduleTimer(now)
        guard cacheFresh(now), let best = messages.first(where: { eligible($0, now) }) else { return }
        if let cur = current {
            if queue && cur.id != best.id { pending = true }
            return
        }
        if isPaused || hosts.isEmpty || !foreground { return }
        // A message back after a pause goes first; what came due meanwhile
        // follows when it closes.
        if local[best.id]?.interrupted == true { pending = true }
        displayed = false
        current = best
    }

    /// A cache without a fetch time (written by hand) counts as fresh.
    private func cacheFresh(_ now: Date) -> Bool {
        guard let at = fetchedAt else { return true }
        return now.timeIntervalSince(at) <= cacheMaxAge
    }

    private func eligible(_ m: InAppMessage, _ now: Date) -> Bool {
        if failed.contains(m.id) { return false }
        if let start = m.startAt, now < start { return false }
        if let end = m.endAt, now >= end { return false }
        let l = local[m.id]
        if let l, l.interrupted { return triggered(m, now) }
        let shown = max(l?.shown ?? 0, m.shown)
        let last = Self.later(l?.last, m.lastShownAt)
        if let max = m.frequency.maxDisplays, shown >= max { return false }
        switch m.frequency.kind {
        case .once:
            if shown > 0 { return false }
        case .everySession:
            if l?.session == sessionCount { return false }
        case .interval:
            if let last, now.timeIntervalSince(last) < m.frequency.interval { return false }
        }
        return triggered(m, now)
    }

    private func triggered(_ m: InAppMessage, _ now: Date) -> Bool {
        m.triggers.isEmpty || m.triggers.contains { group in group.allSatisfy { holds($0, now) } }
    }

    private func holds(_ c: InAppCondition, _ now: Date) -> Bool {
        switch c.kind {
        case .sessionCount:
            return Self.compare(Double(sessionCount), c.op, c.seconds)
        case .sessionTime:
            return Self.compare(now.timeIntervalSince(sessionStart).rounded(.down), c.op, c.seconds)
        case .sinceInstall:
            return Self.compare(now.timeIntervalSince(installedAt ?? now).rounded(.down), c.op, c.seconds)
        case .custom:
            let v = c.key.flatMap { triggers[$0] }
            switch c.op {
            case "exists": return v != nil
            case "not_exists": return v == nil
            case "in": return v.map { c.values.contains($0.text) } ?? false
            case "=": return v.map { Self.equal($0, c.value) } ?? false
            case "!=": return v.map { !Self.equal($0, c.value) } ?? true
            default:
                guard let a = v?.number, let b = Self.number(c.value) else { return false }
                return Self.compare(a, c.op, b)
            }
        }
    }

    static func compare(_ a: Double, _ op: String, _ b: Double) -> Bool {
        switch op {
        case "=": return a == b
        case "!=": return a != b
        case ">": return a > b
        case ">=": return a >= b
        case "<": return a < b
        case "<=": return a <= b
        default: return false
        }
    }

    /// A condition value as a number: numbers, and strings that read as one.
    private static func number(_ v: JSON?) -> Double? {
        switch v {
        case .int(let n): return Double(n)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Numbers compare as numbers ("5" = 5.0), the rest as text.
    private static func equal(_ a: InAppTrigger, _ b: JSON?) -> Bool {
        guard let b, b != .null else { return false }
        if let x = a.number, let y = number(b) { return x == y }
        return a.text == InAppParse.text(b)
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    /// Wakes up when a session_time or since_install condition comes true.
    private func scheduleTimer(_ now: Date) {
        timer?.cancel()
        timer = nil
        var next: Date?
        for m in messages {
            for group in m.triggers {
                for c in group where c.op == ">=" {
                    let at: Date?
                    switch c.kind {
                    case .sessionTime: at = sessionStart.addingTimeInterval(c.seconds)
                    case .sinceInstall: at = (installedAt ?? now).addingTimeInterval(c.seconds)
                    default: at = nil
                    }
                    if let at, at > now, next.map({ at < $0 }) ?? true { next = at }
                }
            }
        }
        nextTimeCheck = next
        if let next, next.timeIntervalSince(now) <= Self.maxTimer {
            timer = home.schedule(after: next.timeIntervalSince(now)) { [weak self] in self?.check() }
        }
    }

    // MARK: - Events

    private func queueEvent(_ messageId: String, _ type: String, buttonId: String? = nil) {
        let now = clock()
        // Microseconds keep seq growing even if the saved state is lost and
        // the device keeps its id.
        seq = max(seq + 1, Int(now.timeIntervalSince1970 * 1_000_000))
        events.append(
            Event(messageId: messageId, type: type, buttonId: buttonId, seq: seq, at: InAppParse.formatTime(now)))
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        save()
        if let delay = eventDelay {
            eventTimer?.cancel()
            eventTimer = home.schedule(after: delay) { [weak self] in self?.flushEvents() }
        }
    }

    /// Sends queued events now, in batches. Never fails: what cannot be sent
    /// waits for the next try (refusals for good are dropped).
    func flushEvents(completion: (() -> Void)? = nil) {
        if let completion { sendWaiters.append(completion) }
        if sending { return }
        sending = true
        sendNext()
    }

    private func sendNext() {
        guard !events.isEmpty, !disposed, let c = credentials() else { return finishSending() }
        let batch = Array(events.prefix(Self.eventBatch))
        let api = self.api
        io.execute { [weak self] in
            let result = Result { try api.sendInAppEvents(deviceId: c.deviceId, secret: c.secret, batch.map(\.json)) }
            self?.home.execute { self?.sent(batch, result) }
        }
    }

    private func sent(_ batch: [Event], _ result: Result<Void, Error>) {
        switch result {
        case .success:
            break
        case .failure(let e as DakApiError) where e.isPermanent:
            log.w("DakPush: in-app events refused, dropping them: \(e)")
        case .failure(let e):
            // Offline, or the device is registering again: later.
            log.d("dak: in-app events not sent yet: \(e)")
            return finishSending()
        }
        // By seq: the list may have changed meanwhile (new events, or a
        // reload that merged saved ones in front).
        let done = Set(batch.map(\.seq))
        events.removeAll { done.contains($0.seq) }
        save()
        sendNext()
    }

    private func finishSending() {
        sending = false
        let waiters = sendWaiters
        sendWaiters = []
        for w in waiters { w() }
    }

    // MARK: - Persistence

    /// A read that fails (a locked iPhone) leaves the controller running from
    /// memory without saving; the next resume reads it again and keeps what
    /// happened meanwhile.
    private func reload() {
        if reloading { return }
        reloading = true
        let store = self.store
        io.execute { [weak self] in
            let result = Result { try store.read() }
            self?.home.execute { self?.reloaded(result) }
        }
    }

    private func reloaded(_ result: Result<Data?, Error>) {
        reloading = false
        guard case .success(let data) = result else {
            log.d("dak: in-app state still not readable")
            return
        }
        if canSave || disposed { return }
        let mem = (
            raw: raw, etag: etag, fetchedAt: fetchedAt, fetchedFor: fetchedFor, local: local,
            sessions: sessionCount, installedAt: installedAt, events: events, seq: seq
        )
        reset()
        restore(data)
        // Keep what happened while it could not be read: sessions and shows
        // continue the saved counts, events are still sent.
        let before = sessionCount
        sessionCount += mem.sessions
        for (id, l) in mem.local {
            let saved = local[id]
            local[id] = Local(
                shown: (saved?.shown ?? 0) + l.shown, last: Self.later(saved?.last, l.last),
                session: l.session > 0 ? l.session + before : (saved?.session ?? 0),
                interrupted: l.interrupted || (saved?.interrupted ?? false))
        }
        if installedAt == nil { installedAt = mem.installedAt }
        events += mem.events
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        seq = max(seq, mem.seq)
        if mem.fetchedAt != nil {
            raw = mem.raw
            etag = mem.etag
            fetchedAt = mem.fetchedAt
            fetchedFor = mem.fetchedFor
            messages = parse(raw)
        }
        canSave = true
        save()
        evaluate()
    }

    private func reset() {
        raw = []
        etag = nil
        fetchedAt = nil
        fetchedFor = nil
        local = [:]
        sessionCount = 0
        installedAt = nil
        events = []
        seq = 0
        messages = []
    }

    /// Unreadable parts of the saved state are left out, never all of it.
    private func restore(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        guard let js = JSON.decodeObject(data) else {
            log.w("dak: ignoring unreadable in-app state")
            return
        }
        raw = js["messages"]?.array ?? []
        etag = js["etag"]?.string
        fetchedAt = Self.date(js["fetched_at"])
        fetchedFor = js["fetched_for"]?.string
        local = (js["local"]?.object ?? [:]).compactMapValues(Local.init(json:))
        sessionCount = js["sessions"]?.int ?? 0
        installedAt = Self.date(js["installed_at"])
        events = (js["events"]?.array ?? []).compactMap(Event.init(json:))
        seq = js["seq"]?.int ?? 0
        messages = parse(raw)
    }

    /// Saving can fail (a full disk, a locked phone); the state then lives in
    /// memory until the next save works.
    private func save() {
        guard canSave else { return }
        var js: [String: JSON] = [
            "v": .int(1),
            "messages": .array(raw),
            "etag": JSON(etag),
            "fetched_for": JSON(fetchedFor),
            "local": .object(local.mapValues(\.json)),
            "sessions": .int(sessionCount),
            "events": .array(events.map(\.json)),
            "seq": .int(seq),
        ]
        if let fetchedAt { js["fetched_at"] = .int(Self.millis(fetchedAt)) }
        if let installedAt { js["installed_at"] = .int(Self.millis(installedAt)) }
        let data = JSON.encode(js)
        let store = self.store
        let log = self.log
        io.execute {
            do { try store.write(data) } catch { log.w("dak: could not save the in-app state: \(error)") }
        }
    }

    static func millis(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded()) }

    static func date(_ v: JSON?) -> Date? {
        v?.int.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Stops the timers.
    func dispose() {
        disposed = true
        timer?.cancel()
        eventTimer?.cancel()
    }
}
