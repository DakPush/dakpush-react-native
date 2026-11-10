import Foundation

/// An error answer from the Dak server.
struct DakApiError: Error, CustomStringConvertible {
    let status: Int
    /// The server's error code, like `identity_verification_failed`; for an
    /// answer that is not Dak's own JSON error, `http_` and the status.
    let code: String
    let message: String
    /// The request field the server refused, like `tags` or `external_id`.
    var field: String? = nil
    /// The answer is Dak's own JSON error. A proxy in front of it (an HTML
    /// 403, a 404 page) is not, and is treated as a network problem: retried,
    /// never acted on.
    var fromDak = true
    /// How long the server asked the SDK to wait (Retry-After on 429 and 503).
    var retryAfter: TimeInterval? = nil

    /// The device is unknown or its secret is wrong: register again.
    var isUnauthorized: Bool { fromDak && status == 401 }

    /// Retrying the same request cannot succeed (bad input, identity check).
    var isPermanent: Bool {
        fromDak && (400..<500).contains(status) && ![401, 408, 429].contains(status)
    }

    var description: String { "DakApiError(\(status) \(code): \(message))" }
}

/// An answer that cannot be right (not JSON, no secret): a network problem.
struct DakBadAnswer: Error, CustomStringConvertible {
    let description: String
}

/// What the server answers to a registration.
struct DakRegistration: Equatable {
    let deviceId: String
    let deviceSecret: String
}

/// The in-app messages for a device, with the ETag to send next time.
struct DakInAppList {
    let messages: [Any]
    let etag: String?
}

struct DakHTTPResponse {
    let status: Int
    /// Header names in lower case.
    let headers: [String: String]
    let body: Data

    var isSuccess: Bool { (200..<300).contains(status) || status == 304 }
}

/// One HTTP exchange. Tests replace it; the SDK uses [URLSessionHTTP].
protocol DakHTTP: AnyObject {
    /// Sends the request and reads the whole answer within [timeout]. Throws
    /// for network problems.
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) throws
        -> DakHTTPResponse
}

/// [DakHTTP] on URLSession. The worker waits for the answer, so calls go out
/// one at a time and in order.
final class URLSessionHTTP: NSObject, DakHTTP, @unchecked Sendable {
    static let maxBodyBytes = 2 * 1024 * 1024

    private let session: URLSession

    /// [protocolClasses] are for tests (a fake server).
    init(protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let delegate = RedirectRefuser()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) throws
        -> DakHTTPResponse
    {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        let done = DispatchSemaphore(value: 0)
        let result = Locked<Result<DakHTTPResponse, Error>?>(nil)
        let task = session.dataTask(with: request) { data, response, error in
            result.value = Self.result(data, response, error)
            done.signal()
        }
        task.resume()
        // A server that sends headers and then stalls would otherwise hold
        // every later call: the deadline covers the whole exchange.
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        return try result.value!.get()
    }

    private static func result(_ data: Data?, _ response: URLResponse?, _ error: Error?) -> Result<
        DakHTTPResponse, Error
    > {
        if let error { return .failure(error) }
        guard let http = response as? HTTPURLResponse else { return .failure(URLError(.badServerResponse)) }
        let body = data ?? Data()
        if body.count > maxBodyBytes { return .failure(DakBadAnswer(description: "answer larger than \(maxBodyBytes) bytes")) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String { headers[k.lowercased()] = "\(v)" }
        }
        return .success(DakHTTPResponse(status: http.statusCode, headers: headers, body: body))
    }

    /// A redirect is handed back as the answer, never followed: the device
    /// secret must not travel to another URL.
    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

/// The SDK half of Dak's HTTP API.
final class DakApi {
    /// The server URL, checked by [checkBaseURL], without a trailing slash.
    let baseURL: String
    let appId: String
    private let http: DakHTTP
    private let userAgent: String
    /// The time a request may take, sending and reading the answer together.
    private let timeout: TimeInterval

    /// [baseURL] and [appId] must have passed [checkBaseURL] and [checkAppId].
    init(baseURL: String, appId: String, http: DakHTTP, userAgent: String, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.appId = appId
        self.http = http
        self.userAgent = userAgent
        self.timeout = timeout
    }

    private func url(_ path: String) -> URL {
        // Checked parts only: the base URL, the app id, and device ids that
        // passed checkId.
        URL(string: "\(baseURL)/v1/apps/\(appId)\(path)")!
    }

    /// Registers this device and returns its id and secret.
    func register(_ body: [String: JSON]) throws -> DakRegistration {
        let js = try json(send("POST", url("/devices"), body: body, secret: nil).body)
        guard let id = js["device_id"]?.string, Self.checkId(id), let secret = js["device_secret"]?.string,
            !secret.isEmpty
        else { throw DakBadAnswer(description: "registration answer without device_id or device_secret") }
        return DakRegistration(deviceId: id, deviceSecret: secret)
    }

    /// Sends changes to the device (token, user, tags, subscription, and so on).
    func update(deviceId: String, secret: String, _ body: [String: JSON]) throws {
        _ = try send("PATCH", url("/devices/\(deviceId)"), body: body, secret: secret)
    }

    /// A tap on a notification, or on its button [actionId].
    func opened(deviceId: String, secret: String, messageId: String, actionId: String?) throws {
        var body: [String: JSON] = ["message_id": .string(messageId)]
        if let actionId { body["action_id"] = .string(actionId) }
        _ = try send("POST", url("/devices/\(deviceId)/opened"), body: body, secret: secret)
    }

    /// Receipts: these messages arrived on the device (at most 50).
    func delivered(deviceId: String, secret: String, messageIds: [String]) throws {
        _ = try send(
            "POST", url("/devices/\(deviceId)/delivered"), body: ["message_ids": .array(messageIds.map { .string($0) })],
            secret: secret)
    }

    /// The in-app messages this device may show; nil when unchanged since [etag].
    func fetchInApp(deviceId: String, secret: String, etag: String?) throws -> DakInAppList? {
        let res = try send(
            "GET", url("/devices/\(deviceId)/in-app"), body: nil, secret: secret,
            extra: etag.map { ["If-None-Match": $0] } ?? [:])
        if res.status == 304 { return nil }
        let any = try? JSONSerialization.jsonObject(with: res.body)
        guard let js = any as? [String: Any] else { throw DakBadAnswer(description: "the answer is not JSON") }
        return DakInAppList(messages: js["messages"] as? [Any] ?? [], etag: res.headers["etag"])
    }

    /// Reports in-app impressions, clicks and dismissals.
    func sendInAppEvents(deviceId: String, secret: String, _ events: [JSON]) throws {
        _ = try send("POST", url("/devices/\(deviceId)/in-app/events"), body: ["events": .array(events)], secret: secret)
    }

    private func send(
        _ method: String, _ url: URL, body: [String: JSON]?, secret: String?, extra: [String: String] = [:]
    ) throws -> DakHTTPResponse {
        var headers = ["Accept": "application/json", "User-Agent": userAgent]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let secret { headers["Authorization"] = "Device \(secret)" }
        headers.merge(extra) { _, new in new }
        let res = try http.send(
            method: method, url: url, headers: headers, body: body.map(JSON.encode), timeout: timeout)
        if res.isSuccess { return res }
        let retryAfter = Self.parseRetryAfter(res.headers["retry-after"])
        if let err = JSON.decodeObject(res.body)?["error"]?.object, let code = err["code"]?.string, !code.isEmpty {
            let field = err["field"]?.string
            throw DakApiError(
                status: res.status, code: code, message: err["message"]?.string ?? "",
                field: field?.isEmpty == false ? field : nil, retryAfter: retryAfter)
        }
        throw DakApiError(
            status: res.status, code: "http_\(res.status)", message: "HTTP \(res.status)", fromDak: false,
            retryAfter: retryAfter)
    }

    private func json(_ body: Data) throws -> [String: JSON] {
        guard let js = JSON.decodeObject(body) else { throw DakBadAnswer(description: "the answer is not JSON") }
        return js
    }

    // MARK: - Checks

    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// [url] trimmed and without trailing slashes, or nil when it cannot be
    /// right. It must be https (the device secret travels in every request);
    /// plain http is allowed only for this computer (the simulator).
    static func checkBaseURL(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), let host = c.host, !host.isEmpty,
            c.query == nil, c.fragment == nil, c.user == nil,
            c.scheme == "https" || (c.scheme == "http" && localHosts.contains(host))
        else { return nil }
        var out = trimmed
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// The App ID from the DakPush dashboard: it goes into the path.
    static func checkAppId(_ appId: String) -> Bool { checkId(appId) }

    /// Ids that go into a URL path.
    static func checkId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b == 0x2d
        }
    }

    /// Retry-After as seconds or as an HTTP date; nil when absent or unreadable.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        let v = value?.trimmingCharacters(in: .whitespaces) ?? ""
        if v.isEmpty { return nil }
        if let seconds = Int(v) { return seconds < 0 ? nil : TimeInterval(seconds) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let at = format.date(from: v) else { return nil }
        return max(0, at.timeIntervalSince(now))
    }
}
