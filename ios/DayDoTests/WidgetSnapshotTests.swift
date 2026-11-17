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

        let accent = WidgetAccent(hex: "#FF8A1E")
        let outDir = ProcessInfo.processInfo.environment["DAYDO_WIDGET_SHOTS"]
        if let outDir {
            try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        }

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
