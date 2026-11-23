@testable import DayDoCore
import Foundation
import Testing

/// Source-text architecture guards (mirrors server/tests/architecture.test.ts).
/// Each guard: the regex must match `bad` (not hollow), and the set of matching files must equal
/// `allow` exactly. Allow lists may only shrink.
private struct Guard {
    let name: String
    let directories: [String]
    let pattern: String
    let allow: [String]
    /// One violating snippet per alternative of the pattern.
    let bad: [String]
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func swiftFiles(in dirs: [String]) -> [String] {
    var out: [String] = []
    for dir in dirs {
        let base = repoRoot.appendingPathComponent(dir)
        var found = 0
        if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append(String(url.path.dropFirst(repoRoot.path.count + 1)))
                found += 1
            }
        }
        #expect(found > 0, "directory \(dir) is missing or has no Swift files; renamed?")
    }
    return out.sorted()
}

/// Source text with whole-line `//` comments removed.
private func codeLines(_ rel: String) throws -> String {
    let text = try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private let guards: [Guard] = [
    Guard(
        name: "UI targets never import GRDB or SQLite3; they go through DayDoAPI/DayDoStorage",
        directories: ["ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"^\s*(@\w+\s+)*((public|internal|package|private|fileprivate)\s+)?import\s+((class|struct|enum|protocol|func|var|let|typealias)\s+)?(GRDB|SQLite3)\b"#,
        allow: [],
        bad: [
            "@testable import GRDB",
            "import SQLite3",
            "@preconcurrency import GRDB",
            "public import GRDB",
            "internal import SQLite3",
            "package import GRDB",
            "@_exported public import GRDB",
            "import class GRDB.DatabaseQueue",
            "import func SQLite3.sqlite3_open",
        ]
    ),
    Guard(
        name: "DatabaseQueue/DatabasePool are opened only in Storage/AppDatabase.swift",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"\b(DatabaseQueue|DatabasePool)\("#,
        allow: ["DayDoCore/Sources/DayDoCore/Storage/AppDatabase.swift"],
        bad: ["let q = try DatabaseQueue(path: p)", "let p = try DatabasePool(path: p)"]
    ),
    Guard(
        name: "no startOfDay( ; wall-clock times come from time zone date components (DST-safe)",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"\bstartOfDay\("#,
        allow: [],
        bad: ["let d = calendar.startOfDay(for: date)"]
    ),
    Guard(
        name: "no disclaimer literals in the app target",
        directories: ["ios/DayDo"],
        pattern: #"尚未開放|僅存於這台裝置"#,
        allow: [],
        bad: [#"Text("尚未開放")"#, #"Text("僅存於這台裝置")"#]
    ),
    Guard(
        name: "animation curves are centralized in ios/DayDo/Components/Motion.swift",
        directories: ["ios/DayDo"],
        pattern: #"(?:\bAnimation)?\.(spring|snappy|bouncy|smooth|easeOut|easeIn|easeInOut|linear|timingCurve|interpolatingSpring|interactiveSpring)\b|\bwithAnimation\s*\{|\bAnimation\.default\b|(?:withAnimation|\.animation)\s*\(\s*\.default\b"#,
        allow: ["ios/DayDo/Components/Motion.swift"],
        bad: [
            "withAnimation(.snappy) {",
            ".animation(.spring(response: 0.3, dampingFraction: 0.8), value: x)",
            ".easeOut(duration: 0.15)",
            "withAnimation(.smooth)",
            "withAnimation(.bouncy) {",
            "withAnimation(.easeIn(duration: 0.2)) {",
            "withAnimation(.easeInOut(duration: 0.2)) {",
            "withAnimation(.linear(duration: 0.2)) {",
            "withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.3)) {",
            "withAnimation(.interpolatingSpring(stiffness: 170, damping: 15)) {",
            "withAnimation(Animation.spring(response: 0.3, dampingFraction: 0.8)) {",
            "withAnimation(Animation.default) {",
            "withAnimation { open = true }",
            "withAnimation(.interactiveSpring()) {",
            ".animation(.default, value: x)",
            "withAnimation(.default) {",
        ]
    ),
    Guard(
        name: "hard-coded colors in screens/components are centralized in ios/DayDo/Theme/Theme.swift",
        directories: ["ios/DayDo/Screens", "ios/DayDo/Components"],
        pattern: #"\bColor\(\s*hex:|\bColor\.(white|black)\b|(?<![A-Za-z0-9_])\.(white|black)\b"#,
        allow: [
            // Scheme-independent swipe action pill buttons (#F7B500/#1A1206, #FF8A1E/.white, #F2555A/.white).
            "ios/DayDo/Screens/DrawerView.swift",
            // List color picker swatch circles (Palette.listColors).
            "ios/DayDo/Screens/EditListSheet.swift",
            // Member avatar color picker swatches (Member.avatarColors).
            "ios/DayDo/Screens/MeProfileSheet.swift",
            // Accent color picker swatches (Palette.accentOptions).
            "ios/DayDo/Screens/OtherScreens.swift",
            // Sign in with Apple button style (.black in light mode, .white in dark mode).
            "ios/DayDo/Screens/SignInView.swift",
            // File-type attachment badge colors (semantic fixed swatches).
            "ios/DayDo/Screens/TaskDetailSheet.swift",
            // White drag handle capsule inside accent-bordered TimeBlockEditor handles.
            "ios/DayDo/Screens/TimeBlockEditor.swift",
        ],
        bad: [
            ##"Color(hex: "#18191B")"##,
            "Color.white.opacity(0.08)",
            "Color.black.opacity(0.45)",
            ".foregroundStyle(.white)",
            ".shadow(color: .black.opacity(0.35), radius: 10)",
        ]
    ),
    Guard(
        name: "appearance is applied only through AppearanceApplier (window overrideUserInterfaceStyle)",
        directories: ["ios/DayDo", "ios/DayDoWidgets"],
        // .preferredColorScheme(nil) leaves already-presented sheets in the old scheme
        // when switching back to 跟隨系統.
        pattern: #"\.preferredColorScheme\("#,
        allow: [],
        bad: [
            ".preferredColorScheme(.dark)",
            ".preferredColorScheme(model.appearance.colorScheme)",
        ]
    ),
    // Guards against reintroducing the old membership-count member filter (`m.count <= 1`)
    // that treated shared-list membership as visibility instead of task ownership.
    Guard(
        name: "no membership-count member filter",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"SELECT projectId, memberId FROM projectMember WHERE deletedAt IS NULL["']|if\s+[A-Za-z_][A-Za-z0-9_]*\.count\s*<=\s*1\s*\{\s*return\s+mid\s*==\s*meId\s*\}"#,
        allow: [],
        bad: [
            #"let rows = try Row.fetchAll(db, sql: "SELECT projectId, memberId FROM projectMember WHERE deletedAt IS NULL")"#,
            "if m.count <= 1 { return mid == meId }",
        ]
    ),
    // Guards that task ownership (assignee ?? list owner from projectMember role='owner' ?? ownerId ?? me)
    // is implemented in a single place (LocalDayDoAPI) and not duplicated in another module or UI screen.
    Guard(
        name: "task ownership rule lives solely in LocalDayDoAPI",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"\btaskOwnerId\s*\(|\btaskOwnerIds\s*\(|\bfilterTasks\([^)]*ownedBy:|role\s*=\s*'owner'"#,
        allow: ["DayDoCore/Sources/DayDoCore/API/LocalDayDoAPI.swift"],
        bad: [
            "Self.taskOwnerId(assigneeId: t.assigneeId, projectId: t.projectId, projectOwners: projectOwners, meId: meId)",
            "try taskOwnerIds(recs, in: db)",
            "filterTasks(recs, ownedBy: mid, ownerIds: ownerIds)",
            #"sql: "SELECT projectId, memberId FROM projectMember WHERE deletedAt IS NULL AND role = 'owner'""#,
        ]
    ),
    // Guards that member filter UI and effective-filter logic use AppModel.filterMembers
    // (or MemberFilter) rather than raw model.members / members.count > 1.
    Guard(
        name: "per-frame drag offsets live in a small observed object, not a screen's @State (CalendarScreen re-rendered every frame of a month swipe)",
        directories: ["ios/DayDo/Screens"],
        pattern: #"@State\s+(private\s+)?var\s+\w*[dD]rag\w*\s*:\s*CGFloat"#,
        allow: [
            // Light views: the drawer overlay and the root edge-drag handle.
            "ios/DayDo/Screens/DrawerView.swift",
            "ios/DayDo/Screens/RootView.swift",
        ],
        bad: [
            "@State private var hDragOffset: CGFloat = 0",
        ]
    ),
    Guard(
        name: "member filter chips use filterMembers, never raw members",
        directories: ["ios/DayDo"],
        pattern: #"MemberFilterChips\s*\(\s*members:\s*(?:\w+\.)?members\b|\bmembers\.count\s*>\s*1|selection:\s*\$(?:model\.allMemberFilter|memberFilter)\b"#,
        allow: [],
        bad: [
            "MemberFilterChips(members: model.filterMembers, selection: $model.allMemberFilter)",
            "MemberFilterChips(members: model.filterMembers, selection: $memberFilter)",
            "MemberFilterChips(members: model.members, selection: $model.allMemberFilter)",
            "MemberFilterChips(members: members, selection: $memberFilter)",
            "if model.members.count > 1 {",
        ]
    ),
    Guard(
        name: "screens duplicate lists through AppModel.duplicateProject (in-progress guard)",
        directories: ["ios/DayDo/Screens"],
        pattern: #"(?:\$0|api)\.duplicateProject\s*\("#,
        allow: [],
        bad: [
            "await model.perform { try await $0.duplicateProject(id: id) }",
            "try await model.api.duplicateProject(id: id)",
        ]
    ),
    Guard(
        name: "timed draft zone-stamping uses DateDraft.stampTimeZoneIfFloating",
        directories: ["ios/DayDo"],
        pattern: #"\.timeZone\s*=\s*TimeZone\.current"#,
        allow: [],
        bad: [
            "draft.timeZone = TimeZone.current.identifier",
            "if draft.timeZone == nil { draft.timeZone = TimeZone.current.identifier }",
        ]
    ),
    Guard(
        name: "updateTask ignores schedules equal to the localized stored schedule",
        directories: ["DayDoCore/Sources/DayDoCore/API"],
        pattern: #"case\s+let\s+\.set\(\s*(\w+)\s*\)\s*:\s*t\.schedule\s*=\s*\1\b|case\s+\.set\(\s*let\s+(\w+)\s*\)\s*:\s*t\.schedule\s*=\s*\2\b"#,
        allow: [],
        bad: [
            "case let .set(s): t.schedule = s",
            "case .set(let s):\n    t.schedule = s",
        ]
    ),
    Guard(
        name: "start-of-week arithmetic uses LocalDay.startOfWeek",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"adding\(days:\s*-[^)]*\.weekday\)"#,
        allow: ["DayDoCore/Sources/DayDoCore/Support/LocalDay.swift"],
        bad: [
            "let start = first.adding(days: -first.weekday)",
            "let start = sel.adding(days: -sel.weekday)",
        ]
    ),
    Guard(
        name: "column lane packing lives solely in Domain/Grouping.swift",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"lanes\[lane\]"#,
        allow: ["DayDoCore/Sources/DayDoCore/Domain/Grouping.swift"],
        bad: [
            "while lane < lanes.count, lanes[lane].contains(where: { $0.overlaps(range) }) { lane += 1 }",
            "lanes[lane].append(a...b)",
        ]
    ),
    Guard(
        name: "calendar day-span loops live in DayDoCore CalendarProjection, not CalendarScreen",
        directories: ["ios/DayDo/Screens"],
        pattern: #"while\s+\w+\s*<=\s*end\b"#,
        allow: [],
        bad: [
            "while d <= end {",
            "while day <= end {",
        ]
    ),
    Guard(
        name: "time-block editor drag snap and clamp live in DayDoCore TimeGridDrag, not TimeBlockEditor",
        directories: ["ios/DayDo/Screens"],
        pattern: #"\.rounded\(\)\)\s*\*|min\(1440"#,
        allow: [],
        bad: [
            "let dm = Int((drag.translation.height / Self.pxPerMinute / 5).rounded()) * 5",
            "let ns = max(0, min(1440 - 5, s0 + dm))",
        ]
    ),
    Guard(
        name: "time-block editor lane layout uses DayDoCore DayLayout.blocks, not a local lane layout",
        directories: ["ios/DayDo/Screens"],
        pattern: #"\bstruct\s+Laid\b|\blane\s*==\s*0\b"#,
        allow: [],
        bad: [
            "struct Laid { var task: TodoTask; var start: Int; var end: Int; var lane: Int }",
            "let lane = out.contains { $0.lane == 0 && $0.start < end && $0.end > start } ? 1 : 0",
        ]
    ),
    Guard(
        name: "resident-tab loader bookkeeping lives in ios/DayDo/App/ResidentQuery.swift, not Screens",
        directories: ["ios/DayDo/Screens"],
        pattern: #"@State\s+(?:private\s+)?var\s+loaded(?:Reload|Query|Key|Scope)\b|!=\s*loaded(?:Reload|Key)\b"#,
        allow: [],
        bad: [
            "@State private var loadedReload: TaskReload?",
            "@State private var loadedQuery: CalQueryKey?",
            "@State private var loadedKey: SearchKey?",
            "@State private var loadedScope: TaskScope?",
            "guard let reload = activeReload, reload != loadedReload else { return }",
            "guard let key = activeSearchKey, key != loadedKey else { return }",
        ]
    ),
    Guard(
        name: "section classification uses TaskSection.Kind, not raw section-id string comparisons",
        directories: ["ios/DayDo"],
        pattern: #"(?:==|!=)\s*"(?:overdue|today|tomorrow|later|nodate|completed|trash)"|\bhasPrefix\(\s*"day:"\s*\)|\bcase\s+[^:\n]*"(?:overdue|today|tomorrow|later|nodate|completed|trash)""#,
        allow: [],
        bad: [
            #"visibleSections.first(where: { $0.id == "overdue" })"#,
            #"$0.id != "completed""#,
            #"$0.id != "trash""#,
            #"if sectionId == "tomorrow" { return model.today.adding(days: 1) }"#,
            #"if sectionId.hasPrefix("day:") { return LocalDay(String(sectionId.dropFirst(4))) }"#,
            #"case "overdue": Palette.overdue"#,
            #"case "completed", "trash": Palette.textSecondary"#,
        ]
    ),
    Guard(
        name: "screens and components read the current time through DayDoCore Clock (AppModel.now / today), not Date()",
        directories: ["ios/DayDo/Screens", "ios/DayDo/Components"],
        pattern: #"\bDate\(\)"#,
        allow: [],
        bad: [
            "let c = Calendar.current.dateComponents([.hour, .minute], from: Date())",
            "LocalDay(date: Date(), in: .current).year",
            "ISO8601DateFormatter().string(from: Date())",
        ]
    ),
]

@Suite struct ArchitectureTests {
    @Test(arguments: guards.map(\.name))
    func guardHolds(name: String) throws {
        let g = try #require(guards.first { $0.name == name })
        let regex = try NSRegularExpression(pattern: g.pattern, options: [.anchorsMatchLines])
        for sample in g.bad {
            #expect(matches(regex, sample), "guard is hollow: regex misses bad sample \(sample)")
        }
        let files = swiftFiles(in: g.directories)
        #expect(!files.isEmpty, "scanned no files; directories moved?")
        var hits: [String] = []
        for rel in files where matches(regex, try codeLines(rel)) {
            hits.append(rel)
        }
        #expect(hits == g.allow.sorted(), "\(g.name)")
    }

    /// Guards that even inside LocalDayDoAPI there is only one call site computing task ownership
    /// (`taskOwnerIds(_:in:)` -> `taskOwnerId(...)`), shared by `TodoTask.ownerId` (`tasks(_:_:)`),
    /// calendar (`listTasks(TaskQuery)`), and 「全部」 (`listSections(.smart(.all), ...)`).
    @Test func singleTaskOwnershipRuleCallSite() throws {
        let code = try codeLines("DayDoCore/Sources/DayDoCore/API/LocalDayDoAPI.swift")
        let filterCalls = code.components(separatedBy: "filterTasks(").count - 1
        let ownerIdsCalls = code.components(separatedBy: "taskOwnerIds(").count - 1
        let ownerCalls = code.components(separatedBy: "taskOwnerId(").count - 1
        #expect(filterCalls == 2, "Expected 1 definition + 1 call site in fetchActive for filterTasks(, found \(filterCalls)")
        #expect(ownerIdsCalls == 3, "Expected 1 definition + 2 call sites (fetchActive & tasks) for taskOwnerIds(, found \(ownerIdsCalls)")
        #expect(ownerCalls == 2, "Expected 1 definition + 1 call site in taskOwnerIds for taskOwnerId(, found \(ownerCalls)")
        #expect(code.contains("TaskQuery(memberId: memberId)"), "Expected listSections(.smart(.all)) to delegate to fetchActive via TaskQuery(memberId:)")
    }

    /// Every screen that creates a task must hand the result to
    /// `revealCreatedTaskInAll`, or a task added while 「全部」 is filtered to
    /// another member silently disappears (the duplicate action once did).
    /// Every compact calendar cell that shows an owner avatar (sized badges in
    /// TimeGrid) must gate it on the shared title-first width, or a narrow cell
    /// truncates titles like 學校接小安／學校接小明 to the same prefix (review
    /// rounds 2 and 3 each found one cell that skipped the rule).
    @Test func compactOwnerAvatarsKeepTitleFirst() throws {
        let code = try codeLines("ios/DayDo/Screens/CalendarScreen.swift")
        let sizedBadges = code.components(separatedBy: "OwnerAvatarBadge(member: owner, size:").count - 1
        let gates = code.components(separatedBy: "Self.ownerAvatarMinTitleWidth").count - 1
        #expect(sizedBadges > 0, "no sized owner badges found; renamed?")
        #expect(gates >= sizedBadges, "\(sizedBadges) sized owner badges but only \(gates) title-width gates")
    }

    /// TimeGrid hour rows must use a dedicated scroll-id type: plain Int ids collided with the
    /// week columns' `id: \.offset` (0...6), so opening 週 between 05:00 and 09:00 scrolled to
    /// a day column at 00:00 instead of the hour row.
    @Test func timeGridScrollTargetsHourRowID() throws {
        let code = try codeLines("ios/DayDo/Screens/CalendarScreen.swift")
        #expect(code.contains(".id(HourRowID(hour: h))"), "hour rows lost their HourRowID; renamed?")
        #expect(code.contains("proxy.scrollTo(HourRowID(hour: initialHour)"), "initial scroll must target HourRowID")
        #expect(!code.contains(".id(h)"), "hour rows must not use plain Int ids (collide with column offsets)")
    }

    @Test func screensRevealCreatedTasksInAllFilter() throws {
        let files = swiftFiles(in: ["ios/DayDo/Screens"])
        var offenders: [String] = []
        for rel in files {
            let code = try codeLines(rel)
            let creates = code.components(separatedBy: ".createTask(").count - 1
            let reveals = code.components(separatedBy: "revealCreatedTaskInAll(").count - 1
            if creates > reveals { offenders.append(rel) }
        }
        #expect(offenders.isEmpty, "createTask without revealCreatedTaskInAll in \(offenders)")
    }

    private func functionBody(named name: String, in code: String) throws -> String {
        let marker = "func \(name)("
        let startRange = try #require(code.range(of: marker), "Function \(name) not found")
        let openBrace = try #require(code[startRange.upperBound...].firstIndex(of: "{"), "Opening brace for \(name) not found")
        var depth = 0
        var idx = openBrace
        while idx < code.endIndex {
            let ch = code[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[startRange.lowerBound...idx])
                }
            }
            idx = code.index(after: idx)
        }
        Issue.record("Unclosed brace in \(name)")
        return ""
    }

    @Test func attachmentSyncStaysDecoupledFromTaskSyncLoopAndBackoff() throws {
        let code = try codeLines("DayDoCore/Sources/DayDoCore/Sync/SyncEngine.swift")
        let runSyncLoopBody = try functionBody(named: "runSyncLoop", in: code)
        let performSyncCycleBody = try functionBody(named: "performSyncCycle", in: code)

        let uploadAwaitRegex = try NSRegularExpression(
            pattern: #"\bawait\s+(?:self\.)?(?:uploadPendingAttachments|waitForAttachmentUploads|runAttachmentUploadLoop|triggerAttachmentUpload|attachmentUploadTask)\b"#
        )
        #expect(!matches(uploadAwaitRegex, runSyncLoopBody), "runSyncLoop must not await attachment upload work")
        #expect(!matches(uploadAwaitRegex, performSyncCycleBody), "performSyncCycle must not await attachment upload work")

        let retryableCallsTotal = code.components(separatedBy: "nextRetryableError(").count - 1
        let retryableCallsInCycle = performSyncCycleBody.components(separatedBy: "nextRetryableError(").count - 1
        #expect(retryableCallsTotal == 2, "Expected 1 definition + 1 call site in performSyncCycle for nextRetryableError(, found \(retryableCallsTotal)")
        #expect(retryableCallsInCycle == 1, "nextRetryableError( may only be called inside performSyncCycle")

        let backoffIncrements = code.components(separatedBy: "consecutiveRetryableFailures +=").count - 1
        #expect(backoffIncrements == 1, "Expected consecutiveRetryableFailures += only inside nextRetryableError")
        #expect(!code.contains("maxAttachmentUploadsPerCycle"), "Per-cycle upload cap must stay removed")
    }

    /// Guards that `SyncApplier.specs` stays in sync with `ENTITY_NAMES` in
    /// `server/src/sync/entities.ts`. Unregistered entities are silently skipped
    /// while advancing the pull cursor, causing silent data loss.
    @Test func syncApplierSpecsMatchServerEntityNames() throws {
        let source = try codeLines("server/src/sync/entities.ts")
        let arrayRegex = try NSRegularExpression(
            pattern: #"ENTITY_NAMES\s*=\s*\[([^\]]*)\]\s*as\s+const"#
        )
        let arrayMatch = try #require(
            arrayRegex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            "Could not find `ENTITY_NAMES = [ ... ] as const` in server/src/sync/entities.ts"
        )
        let bodyRange = try #require(Range(arrayMatch.range(at: 1), in: source))
        let arrayBody = source[bodyRange]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let commentStart = line.range(of: "//") {
                    return line[..<commentStart.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")

        let quoteRegex = try NSRegularExpression(pattern: #"['"]([^'"]+)['"]"#)
        let parsedNames = quoteRegex.matches(
            in: arrayBody,
            range: NSRange(arrayBody.startIndex..., in: arrayBody)
        ).compactMap { match -> String? in
            Range(match.range(at: 1), in: arrayBody).map { String(arrayBody[$0]) }
        }
        #expect(!parsedNames.isEmpty, "Parsed zero entity names from server/src/sync/entities.ts; parser is hollow")

        let serverEntities = Set(parsedNames)
        #expect(serverEntities.count == parsedNames.count, "Duplicate entity names in server/src/sync/entities.ts ENTITY_NAMES")

        let appEntities = Set(SyncApplier.specFieldNamesByEntity.keys)
        let missingInApp = serverEntities.subtracting(appEntities).sorted()
        let extraInApp = appEntities.subtracting(serverEntities).sorted()
        #expect(
            appEntities == serverEntities,
            "SyncApplier.specs entity mismatch vs server/src/sync/entities.ts ENTITY_NAMES: missing=\(missingInApp), extra=\(extraInApp)"
        )
    }

    /// Destructive/test launch flags (`-DayDoReset`, `-DayDoSkipLogin`, `-DayDoDemo`)
    /// must only be honored inside `#if DEBUG` so Release builds ignore them.
    @Test func destructiveTestLaunchArgsRequireDebugBuild() throws {
        let flags = ["-DayDoReset", "-DayDoSkipLogin", "-DayDoDemo"]

        func requiresDebug(_ condition: String) -> Bool {
            let trimmed = condition.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? condition
            guard !trimmed.contains("||") else { return false }
            return trimmed
                .components(separatedBy: "&&")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains("DEBUG")
        }

        func unguardedHits(in source: String) -> [(line: Int, flag: String)] {
            enum Branch { case debugActive, other }
            var stack: [Branch] = []
            var violations: [(Int, String)] = []
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, raw) in lines.enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.hasPrefix("#if ") {
                    let cond = String(trimmed.dropFirst(4))
                    stack.append(requiresDebug(cond) ? .debugActive : .other)
                    continue
                }
                if trimmed.hasPrefix("#elseif ") {
                    if !stack.isEmpty {
                        let cond = String(trimmed.dropFirst(8))
                        stack[stack.count - 1] = requiresDebug(cond) ? .debugActive : .other
                    }
                    continue
                }
                if trimmed == "#else" || trimmed.hasPrefix("#else ") || trimmed.hasPrefix("#else/") {
                    if !stack.isEmpty {
                        stack[stack.count - 1] = .other
                    }
                    continue
                }
                if trimmed == "#endif" || trimmed.hasPrefix("#endif ") || trimmed.hasPrefix("#endif/") {
                    if !stack.isEmpty {
                        stack.removeLast()
                    }
                    continue
                }
                let inDebug = stack.contains(.debugActive)
                if !inDebug {
                    for flag in flags where trimmed.contains("\"\(flag)\"") {
                        violations.append((index + 1, flag))
                    }
                }
            }
            return violations
        }

        // Verify the guard is non-hollow against synthetic violations and valid samples.
        for flag in flags {
            #expect(!unguardedHits(in: "if args.contains(\"\(flag)\") {}").isEmpty, "guard misses unguarded \(flag)")
            #expect(!unguardedHits(in: "#if DEBUG\n#else\nif args.contains(\"\(flag)\") {}\n#endif").isEmpty, "guard misses #else \(flag)")
            #expect(!unguardedHits(in: "#if DEBUG\n#endif\nif args.contains(\"\(flag)\") {}").isEmpty, "guard misses post-#endif \(flag)")
            #expect(!unguardedHits(in: "#if DEBUG || RELEASE\nif args.contains(\"\(flag)\") {}\n#endif").isEmpty, "guard misses OR condition \(flag)")
            #expect(unguardedHits(in: "#if DEBUG\nif args.contains(\"\(flag)\") {}\n#endif").isEmpty, "false positive inside #if DEBUG for \(flag)")
            #expect(unguardedHits(in: "#if DEBUG && targetEnvironment(macCatalyst)\nif args.contains(\"\(flag)\") {}\n#endif").isEmpty, "false positive inside #if DEBUG && ... for \(flag)")
        }

        let files = swiftFiles(in: ["ios/DayDo"])
        var offenses: [String] = []
        var sawFlags: Set<String> = []
        for rel in files {
            let source = try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
            for flag in flags where source.contains("\"\(flag)\"") {
                sawFlags.insert(flag)
            }
            for hit in unguardedHits(in: source) {
                offenses.append("\(rel):\(hit.line) (\(hit.flag))")
            }
        }
        #expect(sawFlags == Set(flags), "Expected all destructive test flags to exist in ios/DayDo; renamed? saw=\(sawFlags.sorted())")
        #expect(offenses.isEmpty, "Destructive test launch args outside #if DEBUG: \(offenses.joined(separator: ", "))")
    }
}
