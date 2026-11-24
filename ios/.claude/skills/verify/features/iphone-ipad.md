# iPhone and iPad

The touch layouts (compact tabs on iPhone, split view and inline detail on iPad) are proven by the XCUITest suites, not by hand.

## Sub-features

- `ipad-suite` `DayDoIPadTests` covers the split view, inline detail, trash and settings sub-pages (each has lost data or been covered before).
- `iphone-suite` `DayDoFlowTests` covers the compact flows.

## How to get to it (user POV)

- The app on the `DD iPhone 18 Pro` / `DD iPad Pro 11` simulators.

## Driving it with lcu + mac.sh

Preconditions:

- No other session holds a lease on the simulator (`uitest.sh` returns 8 otherwise).

- **iPad.** `ios/scripts/uitest.sh ipad` for the whole suite; required before merging any change under `ios/DayDo/Screens`.
- **iPhone.** `ios/scripts/uitest.sh iphone`.
- **Screenshots.** `TEST_RUNNER_DAYDO_SHOTS=<dir> ios/scripts/uitest.sh ipad -only-testing:DayDoUITests/DayDoIPadTests/<method>`.

## Gotchas

- Tests must not depend on the current time of day (the time grid scrolls to now).
- The iPad suite sometimes logs `App animations complete notification not received`; rerun only that test and say so.
