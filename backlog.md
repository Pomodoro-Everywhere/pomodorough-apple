# App review backlog — all resolved 2026-09-06

Reviews: 2026-09-05 (initial), 2026-09-06 (working tree at `3dc3739` + fixes this session).
Full `PomodoroughMacTests` suite passed; macOS and iOS Simulator builds succeed.

## Resolved

- [x] P1 — Restore published projection + report local save failures (already in source: `AppStatePersistenceCoordinator.swift:488`).
- [x] P1 — iOS foreground timer notifications (already in source: `IOSTimerNotificationCoordinator`).
- [x] P2 — Pull-to-refresh routes through active sync mode (already in source: `AppModel.refreshForPull`).
- [x] P2 — Preserve timer deadlines across alarm queue (already in source: deadline captured before queue).
- [x] P2 — Midnight task-board refresh (already in source: `nextMidnight` task + notifications).
- [x] P2 — AlarmKit resume uses canonical remaining (fixed: `TimerAlarmScheduler.resume` now cancel+schedule; `UnitPositiveTests` updated).
- [x] P2 — History refresh when empty (fixed: `HistoryScreen` empty state is refreshable).
- [x] P2 — Enable timer alerts after skipping onboarding (fixed: Timer Alerts section in `AccountView`).
- [x] P2 — Auto-start guidance copy (fixed: `ServicePatternCard` copy matches behavior).
- [x] P2 — Room join dismissal safety (fixed: `JoinIrohRoomView` uses `.interactiveDismissDisabled(isJoining)` on iOS).

## Validation notes

- Regression tests: `SnapshotReplacementRecoveryTests`, `TimerCompletionSchedulingTests`, `IntegrationPositiveTests`, `UnitPositiveTests` (foreground delegate, midnight DST).
- Original baseline: macOS 650 tests/42 suites; iOS sim 638 tests/41 suites + 5 UI tests.
- `PomodoroughHistoryRefreshUITests.testEmptyHistoryExposesRefreshableScrollAndSurvivesPull`: taps Arrivals on a fresh install, asserts the `history.empty-scroll` container exists, performs a real `swipeDown` pull, and asserts the empty state survives. Passes on sim (2026-09-06). Identifier must sit *after* `.accessibilityRepresentation` — inside it the id is swallowed. Remaining gaps: pull gesture on the nonempty list, midnight view invalidation, delayed-join dismissal.
