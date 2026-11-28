import Foundation
import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import DayDo
import DayDoCore

@MainActor
final class WidgetSnapshotTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    func testRenderAllNineWidgetLayoutsWithDemoData() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-widget-shots-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = LocalDay(year: 2026, month: 11, day: 15).date(minute: 17 * 60 + 30, in: taipei)
        let clock = Clock.fixed(now, timeZone: taipei)

        do {
            let store = try DayDoStorage.openForApp(in: dir, clock: clock)
            try await store.bootstrap()
            try await DemoData.load(into: store.api, today: store.today)
        }

        let readAPI = try DayDoStorage.openReadOnly(in: dir, clock: clock)
        let today = LocalDay(date: now, in: taipei)
        let projects = try await readAPI.listProjects(includeArchived: false)
        let projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        let todayData = try await WidgetTodayData.load(from: readAPI, today: today)
        let nextData = try await WidgetNextData.loadTimeline(from: readAPI, now: now, timeZone: taipei).first?.data
        let calData = try await WidgetCalendarData.loadTimeline(from: readAPI, now: now, timeZone: taipei).first?.data

        XCTAssertEqual(todayData.totalCount, 6)
        XCTAssertEqual(nextData?.currentOrNext?.task.title, "準備週一產品會議簡報")
        XCTAssertNotNil(calData)

        let midWeekNow = LocalDay(year: 2026, month: 11, day: 18).date(minute: 12 * 60, in: taipei)
        let midWeekCalData = try await WidgetCalendarData.loadTimeline(from: readAPI, now: midWeekNow, timeZone: taipei).first?.data
        XCTAssertNotNil(midWeekCalData)

        let denseToday = LocalDay(year: 2026, month: 11, day: 18) // Wednesday
        let denseProjects = [
            "w": Project(id: "w", name: "工作", color: "#4AA8E8", viewMode: "list", kind: "TASK", isInbox: false, ownerId: "me", sortKey: "a", showInSmart: "all", notifyMode: "all", archived: false, memberIds: ["me"], activeCount: 0, createdAt: 0, updatedAt: 0),
            "p": Project(id: "p", name: "個人", color: "#E98A5B", viewMode: "list", kind: "TASK", isInbox: false, ownerId: "me", sortKey: "b", showInSmart: "all", notifyMode: "all", archived: false, memberIds: ["me"], activeCount: 0, createdAt: 0, updatedAt: 0),
            "o": Project(id: "o", name: "行程", color: "#E8C14E", viewMode: "list", kind: "TASK", isInbox: false, ownerId: "me", sortKey: "c", showInSmart: "all", notifyMode: "all", archived: false, memberIds: ["me"], activeCount: 0, createdAt: 0, updatedAt: 0),
        ]
        func denseTask(_ id: String, _ title: String, _ projectId: String, _ day: LocalDay, _ startMin: Int? = nil, _ endMin: Int? = nil) -> TodoTask {
            let sched: Schedule = startMin.map { .timed(day, start: $0, end: endMin, timeZone: "Asia/Taipei") } ?? .allDay(day)
            return TodoTask(
                id: id, projectId: projectId, title: title, content: "", priority: .none, status: 0,
                schedule: sched, start: nil, due: nil, allDay: sched.isAllDay, timeZone: nil,
                reminders: [], repeat: nil, tags: [], items: [], assigneeId: nil, sortKey: id,
                completedAt: nil, createdAt: 0, updatedAt: 0, deletedAt: nil, attachments: [],
                commentCount: 0, sourceRaw: nil, importNote: nil
            )
        }
        // Dense day (6 timed events on Wed 11/18) + dense week across all 7 days for overflow testing.
        let denseTasks: [TodoTask] = [
            denseTask("d1", "產品晨會同步進度", "w", denseToday, 9 * 60, 9 * 60 + 30),
            denseTask("d2", "架構設計討論會議", "w", denseToday, 10 * 60 + 30, 11 * 60 + 30),
            denseTask("d3", "客戶需求訪談紀錄", "o", denseToday, 13 * 60, 14 * 60),
            denseTask("d4", "Q4 季度績效檢討", "w", denseToday, 15 * 60, 16 * 60),
            denseTask("d5", "跨團隊聯調與驗收", "p", denseToday, 17 * 60, 18 * 60),
            denseTask("d6", "晚餐：家族聚餐", "o", denseToday, 19 * 60, 21 * 60),
            denseTask("s1", "週日採買清單", "p", LocalDay(year: 2026, month: 11, day: 15)),
            denseTask("s2", "整理房間與書櫃", "p", LocalDay(year: 2026, month: 11, day: 15), 14 * 60, 16 * 60),
            denseTask("s3", "慢跑五公里", "o", LocalDay(year: 2026, month: 11, day: 15), 17 * 60, 18 * 60),
            denseTask("s4", "準備下週簡報", "w", LocalDay(year: 2026, month: 11, day: 15), 20 * 60, 21 * 60),
            denseTask("m1", "週一站會", "w", LocalDay(year: 2026, month: 11, day: 16), 10 * 60, 10 * 60 + 30),
            denseTask("m2", "繳信用卡帳單", "p", LocalDay(year: 2026, month: 11, day: 16)),
            denseTask("m3", "專案里程碑檢視", "w", LocalDay(year: 2026, month: 11, day: 16), 14 * 60, 15 * 60),
            denseTask("m4", "健身房訓練", "p", LocalDay(year: 2026, month: 11, day: 16), 19 * 60, 20 * 60),
            denseTask("m5", "英文口說練習", "o", LocalDay(year: 2026, month: 11, day: 16), 21 * 60, 22 * 60),
            denseTask("t1", "程式審查", "w", LocalDay(year: 2026, month: 11, day: 17), 11 * 60, 12 * 60),
            denseTask("t2", "牙醫回診", "p", LocalDay(year: 2026, month: 11, day: 17), 15 * 60, 16 * 60),
            denseTask("t3", "讀書會討論", "o", LocalDay(year: 2026, month: 11, day: 17), 20 * 60, 21 * 60),
            denseTask("th1", "法務合約確認", "w", LocalDay(year: 2026, month: 11, day: 19), 10 * 60, 11 * 60),
            denseTask("th2", "設計稿走查", "w", LocalDay(year: 2026, month: 11, day: 19), 14 * 60, 15 * 60),
            denseTask("th3", "接小孩放學", "o", LocalDay(year: 2026, month: 11, day: 19), 17 * 60, 18 * 60),
            denseTask("th4", "補貨日用品", "p", LocalDay(year: 2026, month: 11, day: 19)),
            denseTask("f1", "週五發版驗收", "w", LocalDay(year: 2026, month: 11, day: 20), 11 * 60, 12 * 60),
            denseTask("f2", "慶功聚餐", "o", LocalDay(year: 2026, month: 11, day: 20), 19 * 60, 21 * 60),
            denseTask("f3", "整理週報", "w", LocalDay(year: 2026, month: 11, day: 20), 16 * 60, 17 * 60),
            denseTask("sa1", "週末踏青", "o", LocalDay(year: 2026, month: 11, day: 21), 9 * 60, 15 * 60),
            denseTask("sa2", "洗車", "p", LocalDay(year: 2026, month: 11, day: 21), 16 * 60, 17 * 60),
        ]
        let denseCalData = WidgetCalendarData.build(tasks: denseTasks, projectsById: denseProjects, today: denseToday)

        let accent = WidgetAccent(hex: "#FF8A1E")
        let outDir = ProcessInfo.processInfo.environment["DAYDO_WIDGET_SHOTS"]
        if let outDir {
            try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        }

        // iPad mini landscape widget sizes in pt:
        // small 117x117, medium 253x117, large 253x253, extra large 527x253.
        let specs: [(String, WidgetFamily, CGSize, AnyView)] = [
            ("today-small", .systemSmall, CGSize(width: 162, height: 162), AnyView(TodayWidgetView(data: todayData, family: .systemSmall, accent: accent))),
            ("today-medium", .systemMedium, CGSize(width: 346, height: 162), AnyView(TodayWidgetView(data: todayData, family: .systemMedium, accent: accent))),
            ("today-large", .systemLarge, CGSize(width: 346, height: 364), AnyView(TodayWidgetView(data: todayData, family: .systemLarge, accent: accent))),
            ("next-small", .systemSmall, CGSize(width: 162, height: 162), AnyView(NextWidgetView(data: nextData, family: .systemSmall, accent: accent))),
            ("next-medium", .systemMedium, CGSize(width: 346, height: 162), AnyView(NextWidgetView(data: nextData, family: .systemMedium, accent: accent))),
            ("next-large", .systemLarge, CGSize(width: 346, height: 364), AnyView(NextWidgetView(data: nextData, family: .systemLarge, accent: accent))),
            ("calendar-small", .systemSmall, CGSize(width: 162, height: 162), AnyView(CalendarWidgetView(data: calData, family: .systemSmall, accent: accent))),
            ("calendar-medium", .systemMedium, CGSize(width: 346, height: 162), AnyView(CalendarWidgetView(data: calData, family: .systemMedium, accent: accent))),
            ("calendar-large", .systemLarge, CGSize(width: 346, height: 364), AnyView(CalendarWidgetView(data: calData, family: .systemLarge, accent: accent))),
            ("calendar-xl", .systemExtraLarge, CGSize(width: 715, height: 364), AnyView(CalendarWidgetView(data: calData, family: .systemExtraLarge, accent: accent))),
            ("week-medium", .systemMedium, CGSize(width: 346, height: 162), AnyView(WeekWidgetView(data: calData, family: .systemMedium, accent: accent))),
            ("week-large", .systemLarge, CGSize(width: 346, height: 364), AnyView(WeekWidgetView(data: calData, family: .systemLarge, accent: accent))),
            ("week-medium-ipadmini", .systemMedium, CGSize(width: 253, height: 117), AnyView(WeekWidgetView(data: calData, family: .systemMedium, accent: accent))),
            ("week-large-ipadmini", .systemLarge, CGSize(width: 253, height: 253), AnyView(WeekWidgetView(data: calData, family: .systemLarge, accent: accent))),
            ("week-xl-ipadmini", .systemExtraLarge, CGSize(width: 527, height: 253), AnyView(WeekWidgetView(data: calData, family: .systemExtraLarge, accent: accent))),
            ("week-xl-bold-dense-ipadmini", .systemExtraLarge, CGSize(width: 527, height: 253), AnyView(WeekWidgetView(data: denseCalData, family: .systemExtraLarge, accent: accent).environment(\.legibilityWeight, .bold))),
            ("week-medium-midweek-ipadmini", .systemMedium, CGSize(width: 253, height: 117), AnyView(WeekWidgetView(data: midWeekCalData, family: .systemMedium, accent: accent))),
            ("week-large-midweek-ipadmini", .systemLarge, CGSize(width: 253, height: 253), AnyView(WeekWidgetView(data: midWeekCalData, family: .systemLarge, accent: accent))),
            ("week-xl-midweek-ipadmini", .systemExtraLarge, CGSize(width: 527, height: 253), AnyView(WeekWidgetView(data: midWeekCalData, family: .systemExtraLarge, accent: accent))),
        ]
        _ = projectsById

        // Verify 6-week month rendering at actual iPhone systemLarge size too.
        let sixWeekCal = WidgetCalendarData.build(tasks: [], projectsById: [:], today: LocalDay(year: 2026, month: 8, day: 15))
        XCTAssertEqual(sixWeekCal.monthLayout.weeks.count, 6)
        let sixWeekRenderer = ImageRenderer(
            content: CalendarWidgetView(data: sixWeekCal, family: .systemLarge, accent: accent)
                .frame(width: 346, height: 364)
                .background(WidgetPalette.background)
                .environment(\.colorScheme, .dark)
        )
        sixWeekRenderer.scale = 2.0
        XCTAssertNotNil(sixWeekRenderer.uiImage)

        for (name, family, size, content) in specs {
            let radius: CGFloat = family == .systemLarge ? 24 : 22
            for (schemeName, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                let framed = content
                    .frame(width: size.width, height: size.height)
                    .background(WidgetPalette.background)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(WidgetPalette.border, lineWidth: 1)
                    )
                    .environment(\.colorScheme, scheme)

                let renderer = ImageRenderer(content: framed)
                renderer.scale = 2.0
                let image = renderer.uiImage
                XCTAssertNotNil(image, "Expected rendered \(schemeName) image for \(name)")
                if let image, let outDir {
                    let data = try XCTUnwrap(image.pngData())
                    let prefix = schemeName == "dark" ? "" : "\(schemeName)-"
                    let fileURL = URL(fileURLWithPath: outDir).appendingPathComponent("\(prefix)\(name).png")
                    try data.write(to: fileURL)
                }
            }
        }
    }

    func testWidgetPaletteDarkTokensMatchOriginalHexAndLightDiffers() throws {
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)

        func hex(_ color: Color, traits: UITraitCollection) -> String {
            let resolved = UIColor(color).resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
            return String(
                format: "#%02X%02X%02X",
                Int((r * 255).rounded()),
                Int((g * 255).rounded()),
                Int((b * 255).rounded())
            )
        }

        let pairs: [(String, Color, String, String)] = [
            ("background", WidgetPalette.background, "#1A1B1D", "#FFFFFF"),
            ("border", WidgetPalette.border, "#26282A", "#E3E5E7"),
            ("divider", WidgetPalette.divider, "#26282A", "#E7E9EB"),
            ("dividerSoft", WidgetPalette.dividerSoft, "#2A2C2E", "#E7E9EB"),
            ("text", WidgetPalette.text, "#F1F3F2", "#111314"),
            ("textSecondary", WidgetPalette.textSecondary, "#9BA3A0", "#5F6764"),
            ("textTertiary", WidgetPalette.textTertiary, "#8A928F", "#6F7774"),
            ("textMuted", WidgetPalette.textMuted, "#737B78", "#767E7B"),
            ("textSection", WidgetPalette.textSection, "#C9CFCC", "#3A403E"),
            ("textDay", WidgetPalette.textDay, "#E6E9E8", "#1D201F"),
            ("doneBackground", WidgetPalette.doneBackground, "#26282A", "#ECEDEF"),
            ("doneText", WidgetPalette.doneText, "#7A827F", "#7C8481"),
            ("overdue", WidgetPalette.overdue, "#FF7A70", "#D9383E"),
            ("priority.high", WidgetPalette.priority(.high), "#F2555A", "#E03E43"),
            ("priority.medium", WidgetPalette.priority(.medium), "#F7B500", "#C98F00"),
            ("priority.low", WidgetPalette.priority(.low), "#4E8BF7", "#3270DF"),
            ("priority.none", WidgetPalette.priority(.none), "#7C8582", "#8A928F"),
        ]

        for (name, color, darkHex, lightHex) in pairs {
            XCTAssertEqual(hex(color, traits: darkTraits), darkHex, "Dark mismatch for \(name)")
            XCTAssertEqual(hex(color, traits: lightTraits), lightHex, "Light mismatch for \(name)")
        }

        let accent = WidgetAccent(hex: "#FF8A1E")
        XCTAssertEqual(hex(accent.text, traits: darkTraits), "#FF9635")
        XCTAssertEqual(hex(accent.text, traits: lightTraits), "#B36115")

        XCTAssertNotEqual(
            hex(WidgetPalette.tintedListText("#4AA8E8"), traits: darkTraits),
            hex(WidgetPalette.tintedListText("#4AA8E8"), traits: lightTraits)
        )
    }

    func testWidgetAppearanceModifierForcesLightInsideDarkWindow() async throws {
        let store = try DeviceStore.inMemory()
        try await store.bootstrap()
        let today = store.today
        _ = try await store.api.createTask(CreateTaskInput(
            title: "淺色小工具驗證",
            priority: .high,
            start: today.description,
            allDay: true
        ))
        let data = try await WidgetTodayData.load(from: store.api, today: today)
        let accent = WidgetAccent(hex: "#FF8A1E")

        func cornerPixelHex(appearance: AppAppearance) throws -> String {
            let view = ZStack {
                WidgetPalette.background
                    .widgetAppearance(appearance)
                TodayWidgetView(data: data, family: .systemMedium, accent: accent)
                    .widgetAppearance(appearance)
            }
            .frame(width: 346, height: 162)
            .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 1.0
            let cg = try XCTUnwrap(renderer.cgImage)
            var pixel: [UInt8] = [0, 0, 0, 0]
            let ctx = try XCTUnwrap(CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.draw(cg, in: CGRect(x: -2, y: -(cg.height - 3), width: cg.width, height: cg.height))
            return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
        }

        // Inside a dark environment, `.light` forces #FFFFFF and `.dark` keeps #1A1B1D.
        XCTAssertEqual(try cornerPixelHex(appearance: .light), "#FFFFFF")
        XCTAssertEqual(try cornerPixelHex(appearance: .dark), "#1A1B1D")
        // `.system` leaves the surrounding dark environment untouched.
        XCTAssertEqual(try cornerPixelHex(appearance: .system), "#1A1B1D")
    }
}
