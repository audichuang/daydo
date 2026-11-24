# Mac task columns

The Mac tasks tab is a desktop list: sidebar of smart lists and lists, a dense two-line task list in the middle, and a detail pane on the right whose width the user drags. The top bar is drawn by the app with the title on the left.

## Sub-features

- `tasks-select` clicking a task title opens it in the right pane.
- `tasks-esc` Esc closes the pane unless a text field is being edited.
- `tasks-sidebar-toggle` `sidebar.left` hides and shows the list sidebar.
- `tasks-resize` dragging the divider changes the pane width and it persists.
- `tasks-context-menu` right-click on a row offers 完成, priority, move to list, date, delete.

## How to get to it (user POV)

- The checkbox icon (`rail.tasks`) in the left rail; it is the launch default.

## Driving it with lcu + mac.sh

Preconditions:

- `$S/mac.sh launch` (no screen) and doctor OK.

- **Select.** Click a task title by coordinates; `taskTitleField` shows that title. Shot `tasks-detail`.
- **Esc.** `pressKey('Escape')`; `taskTitleField` is gone. Repeat with the title field focused by a coordinate click: the pane stays.
- **Sidebar toggle.** Click `sidebar.left`; the 今天/明天 rows disappear; click again to bring them back.
- **Resize.** `swift ios/scripts/mac-drag.swift <divider x> <y> <x-120> <y>`; relaunch without `-DayDoReset` is not needed: switch tabs and back, the width holds.

## Gotchas

- Clicking a row by AX index can hit the checkbox and complete the task.
- Kanban lists show the pane only for a selected card.
