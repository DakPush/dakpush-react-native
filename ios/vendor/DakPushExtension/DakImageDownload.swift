import Foundation

/// Downloads a notification image into a temporary file, within a time and a
/// size limit, so a slow or huge image cannot hold the push back. The limits
/// are the Android SDK's.
@_spi(DakInternal) public final class DakImageDownload: NSObject, URLSessionDownloadDelegate {
    public static let maxBytes: Int64 = 5 * 1024 * 1024
    /// For the whole download; the extension has about 30 s for everything.
    public static let timeout: TimeInterval = 8

    private let completion: (URL?) -> Void
    private let maxBytes: Int64
    private var file: URL?

    private init(maxBytes: Int64, completion: @escaping (URL?) -> Void) {
        self.maxBytes = maxBytes
        self.completion = completion
    }

    /// [completion] gets the file, or nil, exactly once. [protocolClasses] are
    /// for tests.
    public static func start(
        _ url: URL, maxBytes: Int64 = maxBytes, timeout: TimeInterval = timeout,
        protocolClasses: [AnyClass]? = nil, completion: @escaping (URL?) -> Void
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": DakPushInfo.userAgent]
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let delegate = DakImageDownload(maxBytes: maxBytes, completion: completion)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        // Lets the task finish, then releases the delegate.
        session.finishTasksAndInvalidate()
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes { downloadTask.cancel() }
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted when this returns.
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
            let ext = Self.fileExtension(response),
            let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
            Int64(size) <= maxBytes
        else { return }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("dak-\(UUID().uuidString).\(ext)")
        if (try? FileManager.default.moveItem(at: location, to: target)) != nil { file = target }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil, let file {
            try? FileManager.default.removeItem(at: file)
            self.file = nil
        }
        completion(file)
    }

    /// Redirects are followed only to https.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    /// An image type, as iOS picks the decoder by the file's extension; nil for
    /// anything else (an HTML error page from a proxy).
    static func fileExtension(_ response: HTTPURLResponse) -> String? {
        let mime = (response.mimeType ?? "").lowercased()
        switch mime {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/jpeg", "image/jpg": return "jpg"
        default: break
        }
        // The types iOS attaches as images.
        let known: Set<String> = ["jpg", "jpeg", "png", "gif"]
        let pathExt = (response.url?.pathExtension ?? "").lowercased()
        if mime.hasPrefix("image/") { return known.contains(pathExt) ? pathExt : "jpg" }
        // Some storage serves images as plain binary.
        if mime == "application/octet-stream" || mime == "binary/octet-stream", known.contains(pathExt) { return pathExt }
        return nil
    }
}
