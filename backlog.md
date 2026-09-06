# App review backlog

## Open — review 2026-09-06

- [ ] **P2 — Small task-composer heading uses low-contrast text in light appearance.** `Sources/Views/TaskComposer.swift:13-16,27` renders the caption-sized “ADD TASK” in `PomodoroughTheme.signal` on the system background. `Sources/PomodoroughTheme.swift:6` hard-codes that foreground to `#FF604F`, yielding approximately 2.98:1 contrast against white. Small text becomes difficult to read for low-vision users. Use an adaptive, darker foreground for text on light surfaces and verify both appearances and Increase Contrast; retain the accent separately for decoration. Source/color-value confirmed.

- [ ] **P2 — Task selection clips even “Unassigned” at the largest accessibility text size.** Runtime-confirmed on iPhone 17 Pro Max / iOS 27 Simulator with `UICTContentSizeCategoryAccessibilityXXXL`: the idle timer's task menu wraps “Unassigned” into two lines and cuts off the second line within its dark panel. `Sources/Views/TimerTaskPicker.swift:63-76` applies a single-line/shrink policy to the menu container, but the rendered picker label still overflows. Provide an explicit label with reliable wrapping and sufficient intrinsic height at accessibility sizes; verify long task names and active/next selectors too. Screenshot: `/tmp/pomodorough-review-xxxl-ready.png` (temporary review artifact).

- [ ] **P3 — Next-task picker hides its purpose during an active timer.** `Sources/Views/TimerTaskPicker.swift:48,54` hides the “Next focus task” label. Sighted users see the active task followed by another task menu without an explanation that changes apply only to the next focus run; that explanation exists only in an accessibility hint. Show “Next focus task” beside the menu and make the current/next distinction visible. Source-confirmed.

- [ ] **P3 — Completed-focus breakdown is hidden behind an unrelated history count.** `Sources/Views/HistoryScreen.swift:66,71` labels its navigation control “N total” visually and “N history entries” for accessibility, but opens a chart restricted to completed focus runs. Users cannot infer the destination, and a history containing only cancelled runs leads from a nonzero count to an empty chart. Use an explicit “Completed focus” / “View focus breakdown” label; show the overall history count separately. Source-confirmed.

- [ ] **P2 — Reduce Motion is ignored by timer/control and task transitions.** `Sources/Views/TimerControls.swift:28`, `Sources/Views/TasksScreen.swift:60`, `Sources/Views/TimerScreen.swift:42`, and `Sources/Views/MainContainer.swift:169,183` install animations without consulting `accessibilityReduceMotion`; macOS additionally animates the actual window resize with `setFrame(... animate: true)`. The only existing Reduce Motion check is in NetworkSectionView. Disable spatial/morphing animations or replace them with a non-spatial transition when requested, including the AppKit resize. Source-confirmed; runtime Reduce Motion comparison pending.

- [ ] **P2 — Visible timer and task actions disappear as accessibility buttons.** `Sources/Views/TimerControls.swift:34` replaces Start/Pause, Finish, Cancel and Stop sound with one button plus custom actions; `Sources/Views/TaskComposer.swift:49` explicitly hides Add task. Voice Control users cannot target the visible secondary button names through matching accessibility buttons; VoiceOver users must discover the actions rotor even for primary task creation. Expose visible actionable controls individually with matching labels; combine only decorative/read-only content. Existing `UITests/PomodoroughAccessibilityUITests.swift:5` asserts the compressed hierarchy rather than verifying each visible action is independently reachable. Source-confirmed; Voice Control runtime test pending.

- [ ] **P2 — System alarm scheduling failure never attempts notification fallback.** `Sources/TimerAlarmScheduler.swift:404,442` propagates an authorized AlarmKit backend's scheduling error before reaching the available notification backend. A backend failure leaves a running timer with no new completion alert even when notifications are authorized. Attempt notification scheduling when AlarmKit scheduling fails, preserving cancellation/duplicate-delivery safeguards, and test with an authorized alarm backend that throws. Source-confirmed; no live OS failure injected.

- [ ] **P2 — Task-board daily totals omit unassigned and deleted-task focus runs.** `Sources/Views/TasksScreen.swift:26` sums only visible task rows; `Sources/AppStatePublisher.swift:122,130` skips unassigned runs and returns only current tasks. Repro: finish an unassigned focus, or finish an assigned focus then delete its task; today's headline count/time shows zero or drops despite history retaining that completed work. Compute headline totals from all completed focus history for the day; keep row totals scoped to tasks. Source-confirmed.

- [ ] **P2 — Accessible timer layout ignores the largest text settings.** `Sources/Views/AccessibleDialFace.swift:15,25` fixes the countdown at 56 points (shrinkable to 60%) and caps the entire readout at `.accessibility1`. Users selecting Accessibility XXL/XXXL receive the same or smaller readout, phase and status instead of their requested size. Use scaled metrics/text styles and wrapping or scrolling without capping essential timer content. Runtime-confirmed: Accessibility M and XXXL show identical countdown, phase and status sizes on iPhone 17 Pro Max / iOS 27 Simulator. Temporary screenshots: `/tmp/pomodorough-review-axm-ready.png`, `/tmp/pomodorough-review-xxxl-ready.png`.

- [ ] **P2 — Task deletion has no confirmation or undo.** `Sources/Views/TasksScreen.swift:43,47` immediately calls `deleteTask`; `Sources/AppModel.swift:588` queues the deletion for sync. An accidental trash tap removes the task and its daily row immediately, with no recovery action or explanation that history remains. Offer Undo backed by a restoring task operation, or confirm deletion. Source-confirmed.

- [ ] **P2 — Timer alert status stays stale after returning from Settings.** `Sources/Views/AccountView.swift:212`: authorization refresh runs only in the section's initial `.task` and after the in-app enable action. Repro: deny alerts, open Account → Open Settings, enable permission, return to the still-open Account sheet; it retains “Off” and the settings action. Revoking permission similarly leaves “On”. Refresh when the scene becomes active, including AlarmKit authorization changes. Source-confirmed; device repro pending.

## Validation — current review

- Reviewed timer controls, task creation/deletion and daily totals, history navigation, account permissions, alarm scheduling and accessibility behavior. Baseline HEAD: `6bc3ee1`; unrelated test/project edits appeared during review and were preserved. This review changes only this backlog.
- iOS Simulator build passed. macOS configured tests passed: 662 tests in 43 suites. iOS configured test run passed: 651 unit/integration tests in 42 suites plus six UI tests. Newly added, concurrent UI test files were not included in this already-started run.
- Code-size audit: zero violations, six documented exceptions. Complexity report completed. `git diff --check -- backlog.md` passed.
- Visually checked idle timer at default text size, Accessibility M and Accessibility XXXL on iPhone 17 Pro Max / iOS 27 Simulator. Two Dynamic Type issues reproduced above. RocketSim accessibility inspection failed with `accessibility_unavailable`; live VoiceOver/Voice Control, real-device permission changes and injected AlarmKit failures remain unverified. Source-only findings explicitly marked.

## Previous review history

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

## Previous validation notes

- Regression tests: `SnapshotReplacementRecoveryTests`, `TimerCompletionSchedulingTests`, `IntegrationPositiveTests`, `UnitPositiveTests` (foreground delegate, midnight DST).
- Original baseline: macOS 650 tests/42 suites; iOS sim 638 tests/41 suites + 5 UI tests.
- `PomodoroughHistoryRefreshUITests.testEmptyHistoryExposesRefreshableScrollAndSurvivesPull`: taps Arrivals on a fresh install, asserts the `history.empty-scroll` container exists, performs a real `swipeDown` pull, and asserts the empty state survives. Passes on sim (2026-09-06). Identifier must sit *after* `.accessibilityRepresentation` — inside it the id is swallowed. Remaining gaps: pull gesture on the nonempty list, midnight view invalidation, delayed-join dismissal.
