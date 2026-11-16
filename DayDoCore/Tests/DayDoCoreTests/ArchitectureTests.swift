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
    let bad: String
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
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append(String(url.path.dropFirst(repoRoot.path.count + 1)))
        }
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
        pattern: #"^\s*(@testable\s+)?import\s+(GRDB|SQLite3)\b"#,
        allow: [],
        bad: "@testable import GRDB"
    ),
    Guard(
        name: "DatabaseQueue/DatabasePool are opened only in Storage/AppDatabase.swift",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"\b(DatabaseQueue|DatabasePool)\("#,
        allow: ["DayDoCore/Sources/DayDoCore/Storage/AppDatabase.swift"],
        bad: "let q = try DatabaseQueue(path: p)"
    ),
    Guard(
        name: "no startOfDay( ; wall-clock times come from time zone date components (DST-safe)",
        directories: ["DayDoCore/Sources", "ios/DayDo", "ios/DayDoWidgets"],
        pattern: #"\bstartOfDay\("#,
        allow: [],
        bad: "let d = calendar.startOfDay(for: date)"
    ),
    Guard(
        name: "no disclaimer literals in the app target",
        directories: ["ios/DayDo"],
        pattern: #"尚未開放|僅存於這台裝置"#,
        allow: [],
        bad: #"Text("尚未開放")"#
    ),
]

@Suite struct ArchitectureTests {
    @Test(arguments: guards.map(\.name))
    func guardHolds(name: String) throws {
        let g = try #require(guards.first { $0.name == name })
        let regex = try NSRegularExpression(pattern: g.pattern, options: [.anchorsMatchLines])
        #expect(matches(regex, g.bad), "guard is hollow: regex does not match its bad sample")
        let files = swiftFiles(in: g.directories)
        #expect(!files.isEmpty, "scanned no files; directories moved?")
        var hits: [String] = []
        for rel in files where matches(regex, try codeLines(rel)) {
            hits.append(rel)
        }
        #expect(hits == g.allow.sorted(), "\(g.name)")
    }
}
