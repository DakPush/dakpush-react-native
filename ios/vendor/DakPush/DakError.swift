import Foundation

/// A change the server refused, such as a wrong auth hash or a bad tag, or a
/// call the SDK refused itself (a bad tag key, a call before
/// ``Dak/initialize(appId:baseURL:options:)``). Network trouble never ends up
/// here: changes are kept and sent later.
public struct DakError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public let message: String
    /// The server's error code, like `identity_verification_failed` or
    /// `invalid`; `not_initialized` before ``Dak/initialize(appId:baseURL:options:)``.
    public let code: String
    /// The field that was refused, like `tags` or `external_id`, if known.
    public let field: String?
    /// The HTTP status of the refusal, or nil when the SDK refused it itself.
    public let status: Int?

    public init(message: String, code: String, field: String? = nil, status: Int? = nil) {
        self.message = message
        self.code = code
        self.field = field
        self.status = status
    }

    public var errorDescription: String? { message }

    public var description: String {
        "DakError(\(code)\(field.map { " \($0)" } ?? ""): \(message))"
    }

    static func invalid(_ message: String, field: String? = nil) -> DakError {
        DakError(message: message, code: "invalid", field: field)
    }

    static let notInitialized = DakError(message: "call Dak.initialize first", code: "not_initialized")
}
