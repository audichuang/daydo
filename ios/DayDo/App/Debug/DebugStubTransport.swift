import MachO
import os
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications
import DayDoCore

#if DEBUG
actor DebugStubTransport: SyncTransport {
    private var didPullSeed = false
    private var sawChecklistPush = false
    private var didPushRemoteContent = false
    private var didFailAttachmentOnce = false
    private var pushedMeId: String?
    private var pushedMeColor: String?
    private var linkedIdentities: [[String: Any]] = []
    private var activeEmailCodes: Set<String> = []

    func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
        let nowMs = EpochMillis(Date().timeIntervalSince1970 * 1000)
        let serverHLC = HLC(ms: nowMs, counter: 0, deviceId: "srv").description

        if method == "POST" && path == "/auth/apple" {
            linkedIdentities = [
                ["provider": "apple", "email": "test@privaterelay.appleid.com", "createdAt": nowMs],
            ]
            return try jsonResponse(200, [
                "accessToken": "debug-access",
                "refreshToken": "debug-refresh",
                "user": ["id": "debug-user"],
                "isNewAccount": true,
                "hasData": false,
                "meMemberId": NSNull(),
                "inboxProjectId": NSNull(),
            ])
        }

        if method == "POST" && path == "/auth/google" {
            linkedIdentities = [
                ["provider": "google", "email": "tester@gmail.com", "createdAt": nowMs],
            ]
            return try jsonResponse(200, [
                "accessToken": "debug-access-2",
                "refreshToken": "debug-refresh-2",
                "user": ["id": "debug-user-2"],
                "isNewAccount": true,
                "hasData": false,
                "meMemberId": NSNull(),
                "inboxProjectId": NSNull(),
            ])
        }

        if method == "POST" && path == "/auth/email/start" {
            guard let body,
                  let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let rawEmail = payload["email"] as? String else {
                return try jsonResponse(400, ["error": "A valid email and deviceId are required"])
            }
            let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard email.contains("@") else {
                return try jsonResponse(400, ["error": "A valid email and deviceId are required"])
            }
            activeEmailCodes.insert(email)
            return try jsonResponse(202, ["sent": true])
        }

        if method == "POST" && path == "/auth/email/verify" {
            guard let body,
                  let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let rawEmail = payload["email"] as? String,
                  let code = payload["code"] as? String else {
                return try jsonResponse(400, ["error": "A valid email, code and deviceId are required"])
            }
            let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard code.trimmingCharacters(in: .whitespacesAndNewlines) == "123456",
                  activeEmailCodes.remove(email) != nil else {
                return try jsonResponse(401, ["error": "Invalid or expired code"])
            }
            linkedIdentities = [
                ["provider": "email", "email": email, "createdAt": nowMs],
            ]
            return try jsonResponse(200, [
                "accessToken": "debug-access-email",
                "refreshToken": "debug-refresh-email",
                "user": ["id": "debug-user-email"],
                "isNewAccount": true,
                "hasData": false,
                "meMemberId": NSNull(),
                "inboxProjectId": NSNull(),
            ])
        }

        if method == "POST" && path == "/auth/refresh" {
            return try jsonResponse(200, [
                "accessToken": "debug-access-refreshed",
                "refreshToken": "debug-refresh-refreshed",
                "hasData": false,
                "meMemberId": NSNull(),
                "inboxProjectId": NSNull(),
                "avatarUrl": NSNull(),
            ])
        }

        if method == "GET" && path == "/me/identities" {
            if linkedIdentities.isEmpty {
                linkedIdentities = [
                    ["provider": "apple", "email": "test@privaterelay.appleid.com", "createdAt": nowMs],
                ]
            }
            return try jsonResponse(200, linkedIdentities)
        }

        if method == "POST" && path == "/auth/link" {
            guard let body,
                  let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let provider = payload["provider"] as? String else {
                return try jsonResponse(400, ["error": "Invalid JSON body"])
            }
            let args = ProcessInfo.processInfo.arguments
            switch provider {
            case "google":
                if args.contains("-DayDoDebugLinkConflictGoogle") {
                    return try jsonResponse(409, ["error": "identity_in_use"])
                }
                if !linkedIdentities.contains(where: { ($0["provider"] as? String) == "google" }) {
                    linkedIdentities.append(["provider": "google", "email": "linked@gmail.com", "createdAt": nowMs])
                }
                return try jsonResponse(200, linkedIdentities)
            case "apple":
                if args.contains("-DayDoDebugLinkConflictApple") {
                    return try jsonResponse(409, ["error": "identity_in_use"])
                }
                if !linkedIdentities.contains(where: { ($0["provider"] as? String) == "apple" }) {
                    linkedIdentities.append(["provider": "apple", "email": "linked@privaterelay.appleid.com", "createdAt": nowMs])
                }
                return try jsonResponse(200, linkedIdentities)
            case "email":
                guard let rawEmail = payload["email"] as? String,
                      let code = payload["code"] as? String else {
                    return try jsonResponse(400, ["error": "A valid email and code are required"])
                }
                let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard code.trimmingCharacters(in: .whitespacesAndNewlines) == "123456" else {
                    return try jsonResponse(401, ["error": "Invalid or expired code"])
                }
                if email == "inuse@example.com" || args.contains("-DayDoDebugLinkConflictEmail") {
                    return try jsonResponse(409, ["error": "identity_in_use"])
                }
                if !linkedIdentities.contains(where: { ($0["provider"] as? String) == "email" && ($0["email"] as? String) == email }) {
                    linkedIdentities.append(["provider": "email", "email": email, "createdAt": nowMs])
                }
                return try jsonResponse(200, linkedIdentities)
            default:
                return try jsonResponse(400, ["error": "provider must be apple, google, or email"])
            }
        }

        if method == "POST" && path == "/sync/push" {
            var results: [[String: Any]] = []
            if let body,
               let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let ops = payload["ops"] as? [[String: Any]] {
                for op in ops {
                    if let entity = op["entity"] as? String {
                        if entity == "checklistItem" {
                            sawChecklistPush = true
                        }
                        if entity == "member" {
                            if let entityId = op["entityId"] as? String {
                                pushedMeId = entityId
                            }
                            if let row = op["row"] as? [String: Any],
                               let color = row["color"] as? String {
                                pushedMeColor = color
                            }
                        }
                    }
                    if let opId = op["opId"] as? String {
                        results.append(["opId": opId, "status": "applied"])
                    }
                }
            }
            return try jsonResponse(200, [
                "results": results,
                "serverTime": serverHLC,
            ])
        }

        if method == "POST" && path == "/sync/pull" {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-DayDoDebugRemoteAttachment"), !didPullSeed {
                didPullSeed = true
                let today = Clock.system.today.description
                let projectId = "debug-att-proj-1"
                let taskId = "debug-att-task-1"
                let attId = "debug-remote-att-1"
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-user",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": projectId,
                                    "name": "附件測試清單",
                                    "color": "#4AA8E8",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": "debug-owner-1",
                                    "sortKey": "z1",
                                    "showInSmart": "all",
                                    "notifyMode": "all",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["name": serverHLC],
                                "serverSeq": 1,
                            ],
                            [
                                "entity": "task",
                                "row": [
                                    "id": taskId,
                                    "projectId": projectId,
                                    "title": "遠端附件任務",
                                    "content": "",
                                    "priority": 0,
                                    "status": 0,
                                    "startDay": today,
                                    "reminders": [],
                                    "tags": [],
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "schedule": serverHLC],
                                "serverSeq": 2,
                            ],
                            [
                                "entity": "attachment",
                                "row": [
                                    "id": attId,
                                    "taskId": taskId,
                                    "fileName": "notes.txt",
                                    "size": 12,
                                    "mimeType": "text/plain",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["fileName": serverHLC],
                                "serverSeq": 3,
                            ],
                        ],
                        "cursor": 3,
                        "hasMore": false,
                    ]],
                    "members": [],
                ])
            }
            let seedRemoteContent = args.contains("-DayDoDebugRemoteContentUpdate")
            if seedRemoteContent && !didPullSeed {
                didPullSeed = true
                let today = Clock.system.today.description
                let projectId = "debug-sync-proj-1"
                let taskId = "debug-sync-task-1"
                let itemId = "debug-sync-item-1"
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-user",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": projectId,
                                    "name": "同步測試清單",
                                    "color": "#4AA8E8",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": "debug-owner-1",
                                    "sortKey": "z1",
                                    "showInSmart": "all",
                                    "notifyMode": "all",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["name": serverHLC],
                                "serverSeq": 1,
                            ],
                            [
                                "entity": "task",
                                "row": [
                                    "id": taskId,
                                    "projectId": projectId,
                                    "title": "同步測試任務",
                                    "content": "初始描述",
                                    "priority": 0,
                                    "status": 0,
                                    "startDay": today,
                                    "reminders": [],
                                    "tags": [],
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "content": serverHLC, "schedule": serverHLC],
                                "serverSeq": 2,
                            ],
                            [
                                "entity": "checklistItem",
                                "row": [
                                    "id": itemId,
                                    "taskId": taskId,
                                    "title": "觸發同步子任務",
                                    "status": 0,
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "status": serverHLC],
                                "serverSeq": 3,
                            ],
                        ],
                        "cursor": 3,
                        "hasMore": false,
                    ]],
                    "members": [],
                ])
            }
            if seedRemoteContent && sawChecklistPush && !didPushRemoteContent {
                didPushRemoteContent = true
                let today = Clock.system.today.description
                let futureHLC = HLC(ms: nowMs + 60_000, counter: 0, deviceId: "srv-other").description
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-user",
                        "rows": [[
                            "entity": "task",
                            "row": [
                                "id": "debug-sync-task-1",
                                "projectId": "debug-sync-proj-1",
                                "title": "同步測試任務",
                                "content": "遠端更新後的描述",
                                "priority": 0,
                                "status": 0,
                                "startDay": today,
                                "reminders": [],
                                "tags": [],
                                "sortKey": "a0",
                                "createdAt": nowMs,
                                "updatedAt": nowMs + 60_000,
                            ],
                            "clocks": [
                                "title": serverHLC,
                                "content": futureHLC,
                                "schedule": serverHLC,
                            ],
                            "serverSeq": 4,
                        ]],
                        "cursor": 4,
                        "hasMore": false,
                    ]],
                    "members": [],
                ])
            }
            let seedViewer = args.contains("-DayDoSeedViewerOverdue") || args.contains("-DayDoSeedViewerOverdueOnly")
            if seedViewer && !didPullSeed {
                didPullSeed = true
                let yesterday = Clock.system.today.adding(days: -1).description
                let ownerId = "debug-owner-1"
                let projectId = "debug-viewer-proj-1"
                let taskId = "debug-viewer-task-1"
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-owner",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": projectId,
                                    "name": "唯讀共享清單",
                                    "color": "#5AC8FA",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": ownerId,
                                    "sortKey": "z1",
                                    "showInSmart": "all",
                                    "notifyMode": "all",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["name": serverHLC],
                                "serverSeq": 1,
                            ],
                            [
                                "entity": "task",
                                "row": [
                                    "id": taskId,
                                    "projectId": projectId,
                                    "title": "唯讀逾期任務",
                                    "content": "",
                                    "priority": 0,
                                    "status": 0,
                                    "startDay": yesterday,
                                    "reminders": [],
                                    "tags": [],
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "schedule": serverHLC],
                                "serverSeq": 2,
                            ],
                        ],
                        "cursor": 2,
                        "hasMore": false,
                    ]],
                    "memberships": [
                        ["projectId": projectId, "scope": "u:debug-owner", "role": "viewer"],
                    ],
                    "members": [[
                        "id": ownerId,
                        "name": "小安",
                        "initial": "安",
                        "color": "#5AC8FA",
                        "isMe": false,
                        "createdAt": nowMs,
                        "updatedAt": nowMs,
                    ]],
                ])
            }
            if args.contains("-DayDoSeedSharedList"), !didPullSeed, let meId = pushedMeId {
                didPullSeed = true
                let today = Clock.system.today.description
                let otherId = "debug-other-member-1"
                let otherColor = Member.avatarColors.first { $0 != pushedMeColor } ?? Member.avatarColors[0]
                let projectId = "debug-shared-proj-1"
                let partnerProjectId = "debug-partner-proj-1"
                return try jsonResponse(200, [
                    "scopes": [
                        [
                            "scope": "u:debug-user",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": projectId,
                                        "name": "家庭採買",
                                        "color": "#4AA8E8",
                                        "viewMode": "list",
                                        "kind": "TASK",
                                        "isInbox": false,
                                        "ownerId": meId,
                                        "sortKey": "z1",
                                        "showInSmart": "all",
                                        "notifyMode": "all",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["name": serverHLC],
                                    "serverSeq": 1,
                                ],
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": projectId,
                                        "memberId": meId,
                                        "role": "owner",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 2,
                                ],
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": projectId,
                                        "memberId": otherId,
                                        "role": "editor",
                                        "createdAt": nowMs + 1,
                                        "updatedAt": nowMs + 1,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 3,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-shared-task-1",
                                        "projectId": projectId,
                                        "title": "買鮮奶",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a0",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC],
                                    "serverSeq": 4,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-shared-task-2",
                                        "projectId": projectId,
                                        "title": "繳水電費",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "assigneeId": otherId,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a1",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC, "assigneeId": serverHLC],
                                    "serverSeq": 5,
                                ],
                            ],
                            "cursor": 5,
                            "hasMore": false,
                        ],
                        [
                            "scope": "u:debug-other",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": partnerProjectId,
                                        "name": "旅行規劃",
                                        "color": "#E8C14E",
                                        "viewMode": "list",
                                        "kind": "TASK",
                                        "isInbox": false,
                                        "ownerId": otherId,
                                        "sortKey": "z2",
                                        "showInSmart": "all",
                                        "notifyMode": "all",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["name": serverHLC],
                                    "serverSeq": 1,
                                ],
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": partnerProjectId,
                                        "memberId": otherId,
                                        "role": "owner",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 2,
                                ],
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": partnerProjectId,
                                        "memberId": meId,
                                        "role": "editor",
                                        "createdAt": nowMs + 1,
                                        "updatedAt": nowMs + 1,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 3,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-partner-task-1",
                                        "projectId": partnerProjectId,
                                        "title": "訂機票",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a0",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC],
                                    "serverSeq": 4,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-partner-task-2",
                                        "projectId": partnerProjectId,
                                        "title": "換日幣",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "assigneeId": meId,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a1",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC, "assigneeId": serverHLC],
                                    "serverSeq": 5,
                                ],
                            ],
                            "cursor": 5,
                            "hasMore": false,
                        ],
                    ],
                    "memberships": [
                        ["projectId": projectId, "scope": "u:debug-user", "role": "owner"],
                        ["projectId": partnerProjectId, "scope": "u:debug-other", "role": "editor"],
                    ],
                    "members": [[
                        "id": otherId,
                        "userId": "debug-other-user-1",
                        "name": "小安",
                        "initial": "小",
                        "color": otherColor,
                        "avatarUrl": (args.contains("-DayDoSeedAvatarPhoto")
                            ? Bundle.main.url(forResource: "DebugAvatar", withExtension: "png")?.absoluteString
                            : nil) as Any,
                        "isMe": false,
                        "createdAt": nowMs,
                        "updatedAt": nowMs,
                    ]],
                ])
            }
            return try jsonResponse(200, [
                "scopes": [],
                "members": [],
            ])
        }

        if method == "GET" && path == "/attachments/debug-remote-att-1/content" {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-DayDoDebugRemoteAttachmentFailOnce") && !didFailAttachmentOnce {
                didFailAttachmentOnce = true
                return try jsonResponse(500, ["error": "Temporary failure"])
            }
            let delayMs = args.contains("-DayDoDebugRemoteAttachmentSlow") ? 10000 : 250
            try await Task.sleep(for: .milliseconds(delayMs))
            return SyncHTTPResponse(status: 200, body: Data("hello remote".utf8))
        }

        if method == "GET" && path == "/invites/slow-ok" {
            try await Task.sleep(for: .milliseconds(2500))
            let expiresAt = EpochMillis(Date().addingTimeInterval(7 * 86400).timeIntervalSince1970 * 1000)
            return try jsonResponse(200, [
                "projectName": "家庭採買",
                "inviterName": "小安",
                "role": "editor",
                "expiresAt": expiresAt,
            ])
        }

        if method == "GET" && path == "/invites/slow-404" {
            try await Task.sleep(for: .milliseconds(2500))
            return try jsonResponse(404, ["error": "Invite not found"])
        }

        if method == "GET" && path == "/invites/slow-500" {
            try await Task.sleep(for: .milliseconds(2500))
            return try jsonResponse(500, ["error": "Server busy"])
        }

        return try jsonResponse(404, ["error": "Not found"])
    }

    private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: object)
        return SyncHTTPResponse(status: status, body: data)
    }
}
#endif
