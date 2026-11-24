# Mac calendar

On the Mac the calendar is the screen the user lives in: a full-width month grid that shows each day's tasks in the cell, a left sidebar with a mini month and the list filter, and a right detail pane that opens when a task is clicked. There is no 清單 mode on the Mac.

## Sub-features

- `cal-month-default` the calendar opens in 月 with tasks visible inside the cells.
- `cal-sidebar-jump` clicking a day in the sidebar mini month jumps there.
- `cal-cross-month` clicking a grey next-month date switches the main view and the sidebar month together.
- `cal-filter` a sidebar list row filters the grid; 全部清單 clears it.
- `cal-inspector` clicking a task opens it in the right pane; Esc closes it.
- `cal-dblclick-add` double-clicking empty space in a cell opens the composer on that date.
- `cal-context-menu` right-clicking a task offers 完成, priority, move, date and delete.
- `cal-narrow` at 900x640 with the pane open the sidebar steps aside; the sidebar button brings it back by closing the pane, except while the pane's date page has an unconfirmed edit.

## How to get to it (user POV)

- The calendar icon in the left rail.
- `$S/mac.sh launch calendar` opens straight on it.

## Driving it with lcu + mac.sh

Preconditions:

- `$S/mac.sh doctor` is OK and the window is 1400x900.

- **Month default.** Read AX: `calendarModeMenu`'s label contains `目前月`, and month cells list task buttons (e.g. `週會、10:00`). Shot `cal-month`.
- **Cross-month.** Click the button inside a grey next-month container (e.g. `12 月 1 日 週二`). `calendarTitle` reads `<yyyy> 年 <m> 月 1 日 …` and the sidebar month button reads the same month. Shot `cal-cross-month`.
- **Filter.** Click sidebar row `工作`; it becomes `(selected)` and only 工作 tasks remain. Click `全部清單` to clear.
- **Inspector.** Click a task button; `taskTitleField` appears with its title. `pressKey('Escape')`; `taskTitleField` is gone.
- **Double-click add.** `click([x,y], {clickCount: 2})` on empty space inside a cell; the composer opens with that date.
- **Context menu.** `click(<task>, {mouseButton: 'right'})`, screenshot the menu, choose `完成`; reopen from the task list to confirm it is completed (a repeating task moves to its next date instead).
- **Narrow.** `$S/mac.sh size 900x640`, open a task: the sidebar is hidden. Open the date row, pick another date without confirming, click `顯示／隱藏側欄`: the pane and the picked date stay.

## Gotchas

- Clicking a date number opens the day view; the cell body is the double-click target.
- The detail pane width comes from the `macDetailWidth` preference shared with the task columns.
- `+N` in a crowded cell opens the day view, not a popover.
