import Foundation

/// Arbitrary JSON value preserving integer vs boolean types for wire serialization.
public enum SyncJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SyncJSONValue])
    case object([String: SyncJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([SyncJSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: SyncJSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(b): try container.encode(b)
        case let .int(i): try container.encode(i)
        case let .double(d): try container.encode(d)
        case let .string(s): try container.encode(s)
        case let .array(a): try container.encode(a)
        case let .object(o): try container.encode(o)
        }
    }

    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var int64Value: Int64? {
        if case let .int(i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }
}

// MARK: - Push Wire Types

struct SyncPushRequest: Encodable, Sendable {
    let deviceId: String
    let ops: [SyncPushOp]
}

struct SyncPushOp: Encodable, Sendable {
    let opId: String
    let hlc: String
    let entity: String
    let entityId: String
    let op: String
    let fields: [String]
    let row: [String: SyncJSONValue]
}

struct SyncPushResponse: Decodable, Sendable {
    let results: [SyncPushOpResult]
    let serverTime: String
}

struct SyncPushOpResult: Decodable, Sendable {
    let opId: String
    let status: String
    let reason: String?
    let row: [String: SyncJSONValue]?
    let clocks: [String: String]?
    let gone: Bool?
}

// MARK: - Pull Wire Types

struct SyncPullRequest: Encodable, Sendable {
    let cursors: [String: Int64]
    let limit: Int
}

struct SyncPullResponse: Decodable, Sendable {
    let scopes: [SyncPullScope]
    let memberships: [SyncPullMembership]?
    let members: [[String: SyncJSONValue]]?
}

struct SyncPullScope: Decodable, Sendable {
    let scope: String
    let rows: [SyncPullRow]
    let cursor: Int64
    let hasMore: Bool
}

struct SyncPullRow: Decodable, Sendable {
    let entity: String
    let entityId: String?
    let row: [String: SyncJSONValue]?
    let clocks: [String: String]?
    let gone: Bool?
    let serverSeq: Int64
}

struct SyncPullMembership: Decodable, Sendable {
    let projectId: String
    let scope: String
    let role: String
}

// MARK: - Auth Wire Types

struct AuthRefreshRequest: Encodable, Sendable {
    let refreshToken: String
}

struct AuthRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let hasData: Bool?
    let meMemberId: String?
    let inboxProjectId: String?
}

public struct AuthGoogleRequest: Codable, Sendable {
    public let idToken: String
    public let deviceId: String

    public init(idToken: String, deviceId: String) {
        self.idToken = idToken
        self.deviceId = deviceId
    }
}

public struct AuthLoginUser: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct AuthLoginResponse: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let user: AuthLoginUser
    public let isNewAccount: Bool
    public let hasData: Bool
    public let meMemberId: String?
    public let inboxProjectId: String?
}
