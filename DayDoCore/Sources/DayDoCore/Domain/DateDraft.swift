import Foundation

/// Editable copy of a task's date settings used by the date panel and the
/// time block editor until confirmed.
public struct DateDraft: Equatable, Sendable {
    public var day: LocalDay?
    public var endDay: LocalDay?
    public var allDay = true
    public var start = 9 * 60
    /// Minutes from `day` 00:00; may exceed 1440 (ends next day).
    public var end = 10 * 60
    public var timeZone: String?
    public var reminders: [String] = []
    public var repeatRule: String?

    public init() {}

    public init(task: TodoTask, today: LocalDay) {
        self.init(task: task)
    }

    public init(task: TodoTask) {
        reminders = task.reminders
        repeatRule = task.repeat
        guard let s = task.schedule else { return }
        day = s.startDay
        allDay = s.isAllDay
        timeZone = s.timeZone
        if s.isAllDay {
            endDay = s.isMultiDay ? s.lastDay : nil
        } else {
            start = s.startMinute!
            end = s.endOffsetMinutes ?? start
        }
    }

    public var schedule: Schedule? {
        guard let day else { return nil }
        if allDay { return .allDay(day, through: endDay) }
        if end <= start { return Schedule(startDay: day, startMinute: start, timeZone: timeZone) }
        return Schedule(
            startDay: day,
            startMinute: start,
            endDay: day.adding(days: end / 1440),
            endMinute: end % 1440,
            timeZone: timeZone
        )
    }

    public var duration: Int { end - start }

    /// Stamps `timeZone` when currently floating (`nil`), used when a draft
    /// becomes timed so it pins to the given zone without overwriting an
    /// existing zone.
    public mutating func stampTimeZoneIfFloating(_ identifier: String) {
        if timeZone == nil {
            timeZone = identifier
        }
    }

    /// Fills `input` with only the schedule, reminders, and repeat fields that
    /// changed relative to `task`. Sends `schedule` only when date, time, or
    /// timezone actually changed so updating reminders or repeat alone preserves
    /// the task's original timezone.
    public func applyChanges(from task: TodoTask, to input: inout UpdateTaskInput) {
        let initial = DateDraft(task: task)
        let scheduleUnchanged = day == initial.day
            && endDay == initial.endDay
            && allDay == initial.allDay
            && start == initial.start
            && end == initial.end
            && timeZone == initial.timeZone
        if !scheduleUnchanged {
            input.schedule = schedule.map { .set($0) } ?? .clear
        }
        if schedule != nil {
            if reminders != initial.reminders {
                input.reminders = reminders
            }
            if repeatRule != initial.repeatRule {
                input.repeat = repeatRule.map { .set($0) } ?? .clear
            }
        }
    }

    /// Returns an `UpdateTaskInput` containing only the changed
    /// schedule/reminders/repeat fields relative to `task`.
    public func updateInput(for task: TodoTask) -> UpdateTaskInput {
        var input = UpdateTaskInput(taskId: task.id)
        applyChanges(from: task, to: &input)
        return input
    }
}
