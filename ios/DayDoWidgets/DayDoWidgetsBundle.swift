import SwiftUI
import WidgetKit
import DayDoCore

private enum WidgetStoreReader {
    static func openAPI(clock: Clock = .system) -> (any DayDoAPI)? {
        try? DayDoStorage.openReadOnly(in: DayDoStorage.defaultDirectory(), clock: clock)
    }
}

private struct SendableBox<T>: @unchecked Sendable {
    let call: (T) -> Void
}

// MARK: - 今日任務

struct TodayEntry: TimelineEntry {
    let date: Date
    let data: WidgetTodayData?
    let accent: WidgetAccent
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        let today = LocalDay(date: Date(), in: .current)
        return TodayEntry(date: Date(), data: WidgetTodayData(today: today, overdueItems: [], todayItems: []), accent: WidgetAccent.fromSharedDefaults())
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let now = Date()
        let accent = WidgetAccent.fromSharedDefaults()
        let finish = SendableBox(call: completion)
        Task {
            let data = await loadCurrent(now: now)
            finish.call(TodayEntry(date: now, data: data, accent: accent))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let tz = TimeZone.current
        let accent = WidgetAccent.fromSharedDefaults()
        let finish = SendableBox(call: completion)
        Task {
            guard let api = WidgetStoreReader.openAPI() else {
                let nextRefresh = LocalDay(date: now, in: tz).adding(days: 1).date(minute: 0, in: tz)
                let entry = TodayEntry(date: now, data: nil, accent: accent)
                finish.call(Timeline(entries: [entry], policy: .after(nextRefresh)))
                return
            }
            do {
                let snapshots = try await WidgetTodayData.loadTimeline(from: api, now: now, timeZone: tz)
                let entries = snapshots.map { TodayEntry(date: $0.date, data: $0.data, accent: accent) }
                finish.call(Timeline(entries: entries, policy: .atEnd))
            } catch {
                let nextRefresh = LocalDay(date: now, in: tz).adding(days: 1).date(minute: 0, in: tz)
                finish.call(Timeline(entries: [TodayEntry(date: now, data: nil, accent: accent)], policy: .after(nextRefresh)))
            }
        }
    }

    private func loadCurrent(now: Date) async -> WidgetTodayData? {
        guard let api = WidgetStoreReader.openAPI() else { return nil }
        let today = LocalDay(date: now, in: .current)
        return try? await WidgetTodayData.load(from: api, today: today)
    }
}

private struct TodayEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TodayEntry

    var body: some View {
        TodayWidgetView(data: entry.data, family: family, accent: entry.accent)
            .containerBackground(WidgetPalette.background, for: .widget)
    }
}

struct DayDoTodayWidget: Widget {
    let kind = "DayDoTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayEntryView(entry: entry)
        }
        .configurationDisplayName("今日任務")
        .description("今天要做什麼。逾期永遠排最前面。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - 下一個行程

struct NextEntry: TimelineEntry {
    let date: Date
    let data: WidgetNextData?
    let accent: WidgetAccent
}

struct NextProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEntry {
        let now = Date()
        let empty = WidgetNextData.build(tasks: [], projectsById: [:], now: now, timeZone: .current)
        return NextEntry(date: now, data: empty, accent: WidgetAccent.fromSharedDefaults())
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) {
        let now = Date()
        let tz = TimeZone.current
        let accent = WidgetAccent.fromSharedDefaults()
        let finish = SendableBox(call: completion)
        Task {
            guard let api = WidgetStoreReader.openAPI() else {
                finish.call(NextEntry(date: now, data: nil, accent: accent))
                return
            }
            let data = try? await WidgetNextData.loadTimeline(from: api, now: now, timeZone: tz).first?.data
            finish.call(NextEntry(date: now, data: data, accent: accent))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
        let now = Date()
        let tz = TimeZone.current
        let accent = WidgetAccent.fromSharedDefaults()
        let finish = SendableBox(call: completion)
        Task {
            guard let api = WidgetStoreReader.openAPI() else {
                let nextRefresh = LocalDay(date: now, in: tz).adding(days: 1).date(minute: 0, in: tz)
                finish.call(Timeline(entries: [NextEntry(date: now, data: nil, accent: accent)], policy: .after(nextRefresh)))
                return
            }
            do {
                let snapshots = try await WidgetNextData.loadTimeline(from: api, now: now, timeZone: tz)
                let entries = snapshots.map { NextEntry(date: $0.date, data: $0.data, accent: accent) }
                finish.call(Timeline(entries: entries, policy: .atEnd))
            } catch {
                let nextRefresh = LocalDay(date: now, in: tz).adding(days: 1).date(minute: 0, in: tz)
                finish.call(Timeline(entries: [NextEntry(date: now, data: nil, accent: accent)], policy: .after(nextRefresh)))
            }
        }
    }
}

private struct NextEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NextEntry

    var body: some View {
        NextWidgetView(data: entry.data, family: family, accent: entry.accent)
            .containerBackground(WidgetPalette.background, for: .widget)
    }
}

struct DayDoNextWidget: Widget {
    let kind = "DayDoNextWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextProvider()) { entry in
            NextEntryView(entry: entry)
        }
        .configurationDisplayName("下一個行程")
        .description("接下來要去哪裡。只看有時間的項目。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - 日曆

struct CalendarEntry: TimelineEntry {
    let date: Date
    let data: WidgetCalendarData?
    let accent: WidgetAccent
}

struct CalendarProvider: TimelineProvider {
    private static func showCompletedPreference() -> Bool {
        let defaults = UserDefaults(suiteName: DayDoStorage.appGroup)
        if let value = defaults?.object(forKey: "calendarShowCompleted") as? Bool {
            return value
        }
        return true
    }

    func placeholder(in context: Context) -> CalendarEntry {
        let now = Date()
        let today = LocalDay(date: now, in: .current)
        let empty = WidgetCalendarData.build(tasks: [], projectsById: [:], today: today)
        return CalendarEntry(date: now, data: empty, accent: WidgetAccent.fromSharedDefaults())
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        let now = Date()
        let tz = TimeZone.current
        let accent = WidgetAccent.fromSharedDefaults()
        let includeCompleted = Self.showCompletedPreference()
        let finish = SendableBox(call: completion)
        Task {
            guard let api = WidgetStoreReader.openAPI() else {
                finish.call(CalendarEntry(date: now, data: nil, accent: accent))
                return
            }
            let data = try? await WidgetCalendarData.loadTimeline(
                from: api,
                now: now,
                timeZone: tz,
                includeCompleted: includeCompleted
            ).first?.data
            finish.call(CalendarEntry(date: now, data: data, accent: accent))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        let now = Date()
        let tz = TimeZone.current
        let accent = WidgetAccent.fromSharedDefaults()
        let includeCompleted = Self.showCompletedPreference()
        let finish = SendableBox(call: completion)
        Task {
            guard let api = WidgetStoreReader.openAPI() else {
                let nextRefresh = LocalDay(date: now, in: tz).adding(days: 1).date(minute: 0, in: tz)
                finish.call(Timeline(entries: [CalendarEntry(date: now, data: nil, accent: accent)], policy: .after(nextRefresh)))
                return
            }
            do {
                let snapshots = try await WidgetCalendarData.loadTimeline(
                    from: api,
                    now: now,
                    timeZone: tz,
                    includeCompleted: includeCompleted
                )
                let entries = snapshots.map { CalendarEntry(date: $0.date, data: $0.data, accent: accent) }
                finish.call(Timeline(entries: entries, policy: .atEnd))
            } catch {
                let nextRefresh = LocalDay(date: now, in: tz).adding(days: 1).date(minute: 0, in: tz)
                finish.call(Timeline(entries: [CalendarEntry(date: now, data: nil, accent: accent)], policy: .after(nextRefresh)))
            }
        }
    }
}

private struct CalendarEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CalendarEntry

    var body: some View {
        CalendarWidgetView(data: entry.data, family: family, accent: entry.accent)
            .containerBackground(WidgetPalette.background, for: .widget)
    }
}

struct DayDoCalendarWidget: Widget {
    let kind = "DayDoCalendarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalendarProvider()) { entry in
            CalendarEntryView(entry: entry)
        }
        .configurationDisplayName("日曆")
        .description("這個月排了什麼。事件名稱、跨日長條與＋N。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Bundle

@main
struct DayDoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DayDoTodayWidget()
        DayDoNextWidget()
        DayDoCalendarWidget()
    }
}
