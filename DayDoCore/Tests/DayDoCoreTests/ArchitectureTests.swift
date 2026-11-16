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
        pattern: #"(?:\bAnimation)?\.(spring|snappy|bouncy|smooth|easeOut|easeIn|easeInOut|linear|timingCurve|interpolatingSpring)\b|\bAnimation\.default\b|(?:withAnimation|\.animation)\s*\(\s*\.default\b"#,
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
            ".animation(.default, value: x)",
            "withAnimation(.default) {",
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
}
