import Foundation

/// Pure coordinate, snapping, hit-testing, and schedule-shifting math for
/// dragging timed blocks and creating ranges on the calendar time grid.
public enum TimeGridDrag {
    public static let stepMinutes = 15
    public static let maxStartMinute = 24 * 60 - stepMinutes
    public static let minBlockHeight = 18.0

    public struct RangeResult: Equatable, Sendable {
        public var startMinute: Int
        public var endMinute: Int

        public init(startMinute: Int, endMinute: Int) {
            self.startMinute = startMinute
            self.endMinute = endMinute
        }
    }

    public struct MoveResult: Equatable, Sendable {
        public var startDay: LocalDay
        public var startMinute: Int
        /// Minutes from `startDay` 00:00 (may exceed 1440). Equals `startMinute` for point-in-time tasks.
        public var endOffsetMinutes: Int

        public init(startDay: LocalDay, startMinute: Int, endOffsetMinutes: Int) {
            self.startDay = startDay
            self.startMinute = startMinute
            self.endOffsetMinutes = endOffsetMinutes
        }

        public func applied(to task: TodoTask) -> DateDraft {
            var draft = DateDraft(task: task)
            draft.allDay = false
            draft.endDay = nil
            draft.day = startDay
            draft.start = startMinute
            draft.end = endOffsetMinutes
            return draft
        }
    }

    public struct BlockHit: Equatable, Sendable {
        public var columnIndex: Int
        public var day: LocalDay
        public var block: DayLayout.Block

        public init(columnIndex: Int, day: LocalDay, block: DayLayout.Block) {
            self.columnIndex = columnIndex
            self.day = day
            self.block = block
        }
    }

    /// Snaps a minute value to the nearest `step` (default 15) grid line.
    public static func snap(_ rawMinutes: Double, step: Int = stepMinutes) -> Int {
        Int((rawMinutes / Double(step)).rounded()) * step
    }

    /// Maps an X coordinate in the time-grid content space to a clamped column index.
    public static func columnIndex(x: Double, gutter: Double, columnWidth: Double, columnCount: Int) -> Int {
        guard columnWidth > 0, columnCount > 0 else { return 0 }
        let raw = Int(floor((x - gutter) / columnWidth))
        return max(0, min(columnCount - 1, raw))
    }

    /// Converts a vertical drag delta (in points) into a 15-minute snapped minute delta.
    public static func snappedMinuteDelta(dy: Double, hourHeight: Double) -> Int {
        guard hourHeight > 0 else { return 0 }
        return snap(dy / hourHeight * 60.0)
    }

    /// Computes a `[startMinute, endMinute]` range when dragging on an empty slot
    /// from `anchorY` to `currentY` within a single day (`0...1440`, minimum 15 min).
    public static func createRange(anchorY: Double, currentY: Double, hourHeight: Double) -> RangeResult {
        guard hourHeight > 0 else { return RangeResult(startMinute: 0, endMinute: stepMinutes) }
        let anchor = max(0, min(1440, snap(anchorY / hourHeight * 60.0)))
        let current = max(0, min(1440, snap(currentY / hourHeight * 60.0)))
        if current == anchor {
            if anchor >= 1440 {
                return RangeResult(startMinute: maxStartMinute, endMinute: 1440)
            }
            return RangeResult(startMinute: anchor, endMinute: anchor + stepMinutes)
        }
        if current > anchor {
            return RangeResult(startMinute: anchor, endMinute: min(1440, max(anchor + stepMinutes, current)))
        }
        return RangeResult(startMinute: max(0, min(anchor - stepMinutes, current)), endMinute: anchor)
    }

    /// Computes the new schedule when moving an existing timed task block.
    public static func moveSchedule(
        _ schedule: Schedule,
        sourceColumnDay: LocalDay,
        targetColumnDay: LocalDay,
        minuteDelta: Int
    ) -> MoveResult? {
        guard let origStart = schedule.startMinute else { return nil }
        let origDuration = schedule.durationMinutes ?? 0
        let sourceOffset = schedule.startDay.days(until: sourceColumnDay) * 1440
        let relativeStart0 = origStart - sourceOffset
        let clampedRelative: Int
        if minuteDelta == 0 {
            clampedRelative = relativeStart0
        } else {
            let minRelativeStart = -max(0, sourceOffset)
            let maxRelativeStart = max(maxStartMinute, relativeStart0)
            clampedRelative = max(minRelativeStart, min(maxRelativeStart, relativeStart0 + minuteDelta))
        }
        let dayShift = clampedRelative < 0 ? Int(floor(Double(clampedRelative) / 1440.0)) : 0
        let newStartDay = targetColumnDay.adding(days: dayShift)
        let newStartMinute = clampedRelative - dayShift * 1440
        let newEndOffset = origDuration <= 0 ? newStartMinute : newStartMinute + origDuration
        return MoveResult(startDay: newStartDay, startMinute: newStartMinute, endOffsetMinutes: newEndOffset)
    }

    /// Hit-tests laid-out `DayLayout.Block`s in `days` at `(x, y)` in time-grid content coordinates.
    public static func hitTestBlock(
        x: Double,
        y: Double,
        days: [LocalDay],
        tasks: [TodoTask],
        gutter: Double,
        columnWidth: Double,
        hourHeight: Double
    ) -> BlockHit? {
        guard columnWidth > 0, hourHeight > 0, !days.isEmpty else { return nil }
        guard x >= gutter, x < gutter + columnWidth * Double(days.count),
              y >= 0, y <= hourHeight * 24 else { return nil }
        let col = columnIndex(x: x, gutter: gutter, columnWidth: columnWidth, columnCount: days.count)
        let day = days[col]
        let blocks = DayLayout.blocks(for: tasks, on: day)
        let colX = gutter + columnWidth * Double(col)
        for b in blocks.reversed() {
            let laneW = columnWidth / Double(b.lanes)
            let bx = colX + laneW * Double(b.lane) + 1
            let bw = laneW - 2
            let by = Double(b.start) / 60.0 * hourHeight
            let bh = max(Double(b.end - b.start) / 60.0 * hourHeight - 2, minBlockHeight)
            if x >= bx, x <= bx + bw, y >= by, y <= by + bh {
                return BlockHit(columnIndex: col, day: day, block: b)
            }
        }
        return nil
    }

    /// Moves a single-day editor block by `deltaMinutes` (snapped to `step`), preserving
    /// its length, clamping start to `0...(1440 - step)`, and capping end at `maxEnd`.
    public static func move(
        start: Int,
        end: Int,
        deltaMinutes: Double,
        step: Int,
        maxEnd: Int
    ) -> RangeResult {
        let dm = snap(deltaMinutes, step: step)
        let len = end - start
        let ns = max(0, min(1440 - step, start + dm))
        let ne = min(ns + len, maxEnd)
        return RangeResult(startMinute: ns, endMinute: ne)
    }

    /// Resizes a single-day editor block's start by `deltaMinutes` (snapped to `step`),
    /// clamping the new start to `0...(end - step)`.
    public static func resizeStart(
        start: Int,
        end: Int,
        deltaMinutes: Double,
        step: Int,
        maxEnd: Int
    ) -> Int {
        _ = maxEnd
        let dm = snap(deltaMinutes, step: step)
        return max(0, min(start + dm, end - step))
    }

    /// Resizes a single-day editor block's end by `deltaMinutes` (snapped to `step`),
    /// clamping the new end to `(start + step)...maxEnd`.
    public static func resizeEnd(
        start: Int,
        end: Int,
        deltaMinutes: Double,
        step: Int,
        maxEnd: Int
    ) -> Int {
        let dm = snap(deltaMinutes, step: step)
        return min(maxEnd, max(end + dm, start + step))
    }
}
