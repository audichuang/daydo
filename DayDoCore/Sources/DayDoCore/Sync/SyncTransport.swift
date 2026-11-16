import Foundation

/// Response returned by `SyncTransport`.
public struct SyncHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Abstract HTTP transport for sync and auth calls.
public protocol SyncTransport: Sendable {
    func send(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> SyncHTTPResponse
}

/// URLSession-backed `SyncTransport` supporting extra static headers (e.g. Cloudflare Access).
public struct HTTPSyncTransport: SyncTransport, Sendable {
    public let baseURL: URL
    public let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        baseURL: URL,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func send(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> SyncHTTPResponse {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = trimmed.isEmpty ? baseURL : baseURL.appendingPathComponent(trimmed)
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if body != nil && request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return SyncHTTPResponse(status: httpResponse.statusCode, body: data)
    }
}

/// Persistence interface for auth tokens used by `SyncEngine`.
public protocol SyncTokenStore: AnyObject, Sendable {
    var accessToken: String? { get set }
    var refreshToken: String? { get set }
}

/// Thread-safe in-memory `SyncTokenStore` for tests.
public final class InMemorySyncTokenStore: SyncTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _accessToken: String?
    private var _refreshToken: String?

    public init(accessToken: String? = nil, refreshToken: String? = nil) {
        self._accessToken = accessToken
        self._refreshToken = refreshToken
    }

    public var accessToken: String? {
        get { lock.withLock { _accessToken } }
        set { lock.withLock { _accessToken = newValue } }
    }

    public var refreshToken: String? {
        get { lock.withLock { _refreshToken } }
        set { lock.withLock { _refreshToken = newValue } }
    }
}

/// Errors surfaced by `SyncEngine`.
public enum SyncError: Error, LocalizedError, Sendable, Equatable {
    case signedOut
    case retryable(retryAfter: TimeInterval, statusCode: Int?, message: String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut:
            return "Signed out; please sign in again."
        case let .retryable(retryAfter, statusCode, message):
            if let statusCode {
                return "Sync temporarily failed (HTTP \(statusCode), retry after \(Int(retryAfter))s): \(message)"
            }
            return "Sync temporarily failed (retry after \(Int(retryAfter))s): \(message)"
        case let .protocolError(message):
            return "Sync protocol error: \(message)"
        }
    }
}

/// Errors surfaced by remote `ListSharing` API calls.
public enum SharingError: Error, LocalizedError, Sendable, Equatable {
    case badRequest(String)
    case forbidden(String)
    case notFound(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case let .badRequest(message),
             let .forbidden(message),
             let .notFound(message),
             let .conflict(message):
            return message
        }
    }
}
