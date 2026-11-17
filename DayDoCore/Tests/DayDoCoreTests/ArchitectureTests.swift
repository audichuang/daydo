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
}
