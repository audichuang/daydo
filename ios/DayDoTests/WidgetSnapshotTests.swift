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
            ("today-small", .systemSmall, CGSize(width: 170, height: 170), AnyView(TodayWidgetView(data: todayData, family: .systemSmall, accent: accent))),
            ("today-medium", .systemMedium, CGSize(width: 364, height: 170), AnyView(TodayWidgetView(data: todayData, family: .systemMedium, accent: accent))),
            ("today-large", .systemLarge, CGSize(width: 364, height: 382), AnyView(TodayWidgetView(data: todayData, family: .systemLarge, accent: accent))),
            ("next-small", .systemSmall, CGSize(width: 170, height: 170), AnyView(NextWidgetView(data: nextData, family: .systemSmall, accent: accent))),
            ("next-medium", .systemMedium, CGSize(width: 364, height: 170), AnyView(NextWidgetView(data: nextData, family: .systemMedium, accent: accent))),
            ("next-large", .systemLarge, CGSize(width: 364, height: 382), AnyView(NextWidgetView(data: nextData, family: .systemLarge, accent: accent))),
            ("calendar-small", .systemSmall, CGSize(width: 170, height: 170), AnyView(CalendarWidgetView(data: calData, family: .systemSmall, accent: accent))),
            ("calendar-medium", .systemMedium, CGSize(width: 364, height: 170), AnyView(CalendarWidgetView(data: calData, family: .systemMedium, accent: accent))),
            ("calendar-large", .systemLarge, CGSize(width: 364, height: 382), AnyView(CalendarWidgetView(data: calData, family: .systemLarge, accent: accent))),
        ]
        _ = projectsById

        for (name, family, size, content) in specs {
            let radius: CGFloat = family == .systemLarge ? 24 : 22
            let framed = content
                .frame(width: size.width, height: size.height)
                .background(WidgetPalette.background)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(WidgetPalette.border, lineWidth: 1)
                )
                .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2.0
            let image = renderer.uiImage
            XCTAssertNotNil(image, "Expected rendered image for \(name)")
            if let image, let outDir {
                let data = try XCTUnwrap(image.pngData())
                let fileURL = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
                try data.write(to: fileURL)
            }
        }
    }
}
