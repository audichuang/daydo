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

    func upload(
        path: String,
        headers: [String: String],
        fileURL: URL
    ) async throws -> SyncHTTPResponse

    func download(
        path: String,
        headers: [String: String]
    ) async throws -> SyncHTTPResponse
}

public extension SyncTransport {
    func upload(
        path: String,
        headers: [String: String],
        fileURL: URL
    ) async throws -> SyncHTTPResponse {
        let data = try Data(contentsOf: fileURL)
        return try await send(method: "PUT", path: path, headers: headers, body: data)
    }

    func download(
        path: String,
        headers: [String: String]
    ) async throws -> SyncHTTPResponse {
        try await send(method: "GET", path: path, headers: headers, body: nil)
    }
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
        var request = makeRequest(method: method, path: path, headers: headers)
        if body != nil && request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        return try httpResponse(data: data, response: response)
    }

    public func upload(
        path: String,
        headers: [String: String],
        fileURL: URL
    ) async throws -> SyncHTTPResponse {
        var request = makeRequest(method: "PUT", path: path, headers: headers)
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return try httpResponse(data: data, response: response)
    }

    public func download(
        path: String,
        headers: [String: String]
    ) async throws -> SyncHTTPResponse {
        let request = makeRequest(method: "GET", path: path, headers: headers)
        let (data, response) = try await session.data(for: request)
        return try httpResponse(data: data, response: response)
    }

    private func makeRequest(
        method: String,
        path: String,
        headers: [String: String]
    ) -> URLRequest {
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
        return request
    }

    private func httpResponse(data: Data, response: URLResponse) throws -> SyncHTTPResponse {
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

/// Errors surfaced by auth and account-linking API calls.
public enum AuthError: Error, LocalizedError, Sendable, Equatable {
    case identityInUse
    case invalidCode
    case invalidCredentials(String)
    case badRequest(String)
    case differentAccount(AuthLoginResponse)

    public var errorDescription: String? {
        switch self {
        case .identityInUse:
            return "這個登入方式已經屬於另一個 DayDo 帳號"
        case .invalidCode:
            return "驗證碼錯誤或已過期，請再試一次"
        case .invalidCredentials, .badRequest:
            return "驗證失敗，請再試一次"
        case .differentAccount:
            return "已登入其他帳號，請先登出"
        }
    }
}
