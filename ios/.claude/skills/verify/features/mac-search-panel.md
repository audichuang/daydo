# Mac search panel

⌘F opens search as a floating panel over the current tab; Esc or a click on the dimmed backdrop closes it and the tab underneath is unchanged. Picking the task that is already open for editing underneath returns to that editor instead of opening a second one, so a stale draft can never overwrite a newer save.

## Sub-features

- `search-open-close` ⌘F opens, Esc closes, the tab and its sidebar state are unchanged.
- `search-open-result` clicking a result opens its detail.
- `search-same-task` with a task's detail open underneath and an unsaved title edit, picking that same task from search closes the panel and shows the original editor with the draft intact.

## How to get to it (user POV)

- ⌘F anywhere, or the magnifier in the left rail.

## Driving it with lcu + mac.sh

Preconditions:

- `$S/mac.sh launch calendar` and doctor OK.

- **Open/close.** On the tasks tab click `sidebar.left` to collapse the sidebar, `pressKey('cmd+f')`, `pressKey('Escape')`; the sidebar is still collapsed. Shot `search-closed`.
- **Same task.** In the calendar click 媽媽生日, click its title by coordinates, `typeText('XYZ')`, `pressKey('cmd+f')`, `typeText('生日')`, click the result by coordinates. Expect: no panel, the calendar with the pane showing `媽媽生日XYZ`. Shot `search-same-task`.

## Gotchas

- Esc in the panel uses `.keyboardShortcut(.cancelAction)` (an allowlisted unresolved risk): during Zhuyin composition Esc may close the panel instead of cancelling the composition. lcu cannot type through the IME; this needs a person.
- `typeText` of Chinese works for the query because it bypasses the IME.
