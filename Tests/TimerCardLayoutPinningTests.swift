import Foundation
import SwiftUI
import Testing
@testable import Pomodorough

// Pins AP99/AP100 layout decisions: the iOS card stretch rule and the
// portrait top-gap math that keeps the card clear of the toolbar row.
@Suite("Timer card layout pinning")
struct TimerCardLayoutPinningTests {
    @Test func iOSCardStretchesOnlyInLandscape() {
        #expect(TimerMachineCard.iOSCardMaxHeight(for: .landscape) == .infinity)
        #expect(TimerMachineCard.iOSCardMaxHeight(for: .portrait) == nil)
    }

    @Test func portraitTopGapFallsBackWithoutToolbarRow() {
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: 0, globalMinY: 120) == 16)
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: -4, globalMinY: 120) == 16)
    }

    @Test func portraitTopGapClearsReportedToolbarRow() {
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: 200, globalMinY: 100) == 116)
    }

    @Test func portraitTopGapNeverGoesNegative() {
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: 100, globalMinY: 120) == 0)
    }

    @Test func portraitMinimumHeightFloorsAtZero() {
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 30, topGap: 16) == 0)
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 0, topGap: 16) == 0)
    }

    @Test func portraitMinimumHeightDefersToConflictBanner() {
        // Caller contract: portraitContent passes nil while a conflict
        // banner is shown so the card sizes to content; the helper covers
        // the stretch branch only (caller mapping is pinned by
        // check_interface_contract.py).
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 800, topGap: 16) == 761)
    }

    @Test func portraitMinimumHeightFillsTallScreens() {
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 900, topGap: 16) == 861)
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 1366, topGap: 16) == 1327)
    }
}

// Pins the Apple HIGH-findings fixes: VoiceOver rows, proportional dial,
// size-class control/layout gates, shared board columns, full Dynamic Type.
@Suite("Apple HIGH findings")
struct AppleHighFindingsTests {
    @Test func breakdownRowsExposeTaskLabels() {
        let summary = CompletedFocusSummary(
            id: "task-a",
            taskTitle: "Deep work",
            completedPomodoros: 2,
            timeSpentMs: 3_600_000
        )
        #expect(CompletedFocusBreakdownScreen.accessibilityLabel(for: summary) == "Deep work")
        #expect(
            CompletedFocusBreakdownScreen.accessibilityValue(for: summary)
                == "2 completed pomodoros, \(TaskTimeText.spoken(summary.timeSpentMs))"
        )
    }

    @Test func macDialDiameterScalesWithGeometry() {
        let wide = TimerMachineCard.macDialDiameter(for: CGSize(width: 800, height: 500))
        #expect(abs(wide - 480) < 0.01)
        let short = TimerMachineCard.macDialDiameter(for: CGSize(width: 1000, height: 400))
        #expect(abs(short - 400) < 0.01)
    }

    @Test func macDialDiameterAvoidsFixedDeductionCollapse() {
        let narrow = TimerMachineCard.macDialDiameter(for: CGSize(width: 300, height: 400))
        #expect(abs(narrow - 180) < 0.01)
        #expect(TimerMachineCard.macDialDiameter(for: CGSize(width: 0, height: 400)) == 0)
        #expect(TimerMachineCard.macDialDiameter(for: CGSize(width: 300, height: 0)) == 0)
    }

    @Test func singleRowNeedsRegularWidthOrHingeFree() {
        #expect(TimerControls.shouldUseSingleRow(horizontal: .regular, vertical: .regular))
        #expect(TimerControls.shouldUseSingleRow(horizontal: .regular, vertical: .compact))
        #expect(!TimerControls.shouldUseSingleRow(horizontal: .compact, vertical: .regular))
        #expect(!TimerControls.shouldUseSingleRow(horizontal: .compact, vertical: .compact))
        #expect(!TimerControls.shouldUseSingleRow(horizontal: nil, vertical: .regular))
    }

    @Test func singleRowHingeForcesStacked() {
        #expect(!TimerControls.shouldUseSingleRow(horizontal: .regular, vertical: .regular, spansHinge: true))
        #expect(!TimerControls.shouldUseSingleRow(horizontal: .regular, vertical: .compact, spansHinge: true))
    }

    @Test func stackedLandscapeNeedsRegularPair() {
        #expect(TimerScreen.usesStackedLandscape(horizontal: .regular, vertical: .regular))
        #expect(!TimerScreen.usesStackedLandscape(horizontal: .regular, vertical: .compact))
        #expect(!TimerScreen.usesStackedLandscape(horizontal: .compact, vertical: .regular))
        #expect(!TimerScreen.usesStackedLandscape(horizontal: nil, vertical: nil))
    }

    @Test func boardColumnsScaleProportionally() {
        let narrow = TaskBoardColumns.widths(for: 350)
        let wide = TaskBoardColumns.widths(for: 700)
        #expect(abs(wide.finished - narrow.finished * 2) < 0.01)
        #expect(abs(wide.time - narrow.time * 2) < 0.01)
        #expect(abs(wide.action - narrow.action * 2) < 0.01)
        #expect(narrow.finished + narrow.time + narrow.action < 350)
    }

    @Test func boardColumnsShareOneDefinition() {
        #expect(TaskBoardColumns.finishedSpan == 17)
        #expect(TaskBoardColumns.timeSpan == 19)
        #expect(TaskBoardColumns.actionSpan == 13)
        #expect(TaskBoardColumns.widths(for: 0) == TaskBoardColumns.Widths(finished: 0, time: 0, action: 0))
    }

    @Test func pickerSupportsFullDynamicTypeRange() {
        #expect(TimerTaskPicker.pickerLineLimit(for: .large) == 1)
        #expect(TimerTaskPicker.pickerLineLimit(for: .accessibility3) == nil)
        #expect(TimerTaskPicker.pickerScaleFactor(for: .large) == 0.75)
        #expect(TimerTaskPicker.pickerScaleFactor(for: .accessibility3) == 1.0)
    }

    @Test func pickerNeverShrinksBelowReadableFloor() {
        let sizes: [DynamicTypeSize] = [.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        for size in sizes {
            #expect(TimerTaskPicker.pickerScaleFactor(for: size) >= 0.75)
            #expect(TimerTaskPicker.pickerLineLimit(for: size) == nil)
        }
    }

    @Test func pickerUsesLeadingAlignmentInStackedLayout() {
        #expect(TimerTaskPicker.pickerAlignment(for: .large) == .trailing)
        #expect(TimerTaskPicker.pickerAlignment(for: .accessibility3) == .leading)
        #expect(TimerTaskPicker.pickerMultilineAlignment(for: .large) == .trailing)
        #expect(TimerTaskPicker.pickerMultilineAlignment(for: .accessibility3) == .leading)
    }

    @Test func pickerReserveAddsOneLineAtAccessibilitySizes() {
        #if os(iOS)
        #expect(TimerTaskPicker.pickerReserveHeight(for: .large) == 0)
        #expect(TimerTaskPicker.pickerReserveHeight(for: .accessibility3) > 0)
        let large = TimerTaskPicker.menuFont(for: .large).lineHeight
        let xxxl = TimerTaskPicker.menuFont(for: .accessibility5).lineHeight
        #expect(xxxl > large)
        #expect(TimerTaskPicker.pickerReserveHeight(for: .accessibility5) == xxxl)
        #else
        #expect(TimerTaskPicker.pickerReserveHeight(for: .large) == 0)
        #expect(TimerTaskPicker.pickerReserveHeight(for: .accessibility3) == 0)
        #endif
    }
}

// Pins the Apple MEDIUM/LOW-findings fixes: proportional breakdown chart
// with a visible legend, landscape fallback geometry, flexible duration
// minimums, geometry-aware history spacing, scaled clock marks, and the
// proportional backdrop.
@Suite("Apple medium/low findings")
struct AppleMediumLowFindingsTests {
    @Test func breakdownChartHeightScalesWithWidth() {
        #expect(abs(CompletedFocusBreakdownScreen.chartHeight(forWidth: 390) - 390 / 1.35) < 0.01)
        #expect(CompletedFocusBreakdownScreen.chartHeight(forWidth: 500) < CompletedFocusBreakdownScreen.chartHeight(forWidth: 600))
    }

    @Test func breakdownChartHeightStaysBounded() {
        #expect(CompletedFocusBreakdownScreen.chartHeight(forWidth: 0) == 220)
        #expect(CompletedFocusBreakdownScreen.chartHeight(forWidth: -10) == 220)
        #expect(CompletedFocusBreakdownScreen.chartHeight(forWidth: 200) == 220)
        #expect(CompletedFocusBreakdownScreen.chartHeight(forWidth: 2000) == 380)
    }

    @Test func breakdownBadgesClearAAOnEverySlice() {
        for index in 0..<6 {
            let label = CompletedFocusBreakdownScreen.badgeLabelSRGB(at: index)
            let slice = CompletedFocusBreakdownScreen.badgeSliceSRGB(at: index)
            let labelLuminance = PomodoroughTheme.relativeLuminance(red: label.red, green: label.green, blue: label.blue)
            let sliceLuminance = PomodoroughTheme.relativeLuminance(red: slice.red, green: slice.green, blue: slice.blue)
            let ratio = PomodoroughTheme.contrastRatio(
                lighter: max(labelLuminance, sliceLuminance),
                darker: min(labelLuminance, sliceLuminance)
            )
            #expect(ratio >= 4.5)
        }
    }

    @Test func auditSourceMatchesShippedBadgeColors() {
        let porcelain = PomodoroughTheme.porcelainSRGB
        #expect(abs(porcelain.red - 247.0 / 255) < 0.0001)
        #expect(abs(porcelain.green - 248.0 / 255) < 0.0001)
        #expect(abs(porcelain.blue - 242.0 / 255) < 0.0001)
        let danger = PomodoroughTheme.dangerSRGB
        #expect(abs(danger.red - 195.0 / 255) < 0.0001)
        #expect(abs(danger.green - 61.0 / 255) < 0.0001)
        #expect(abs(danger.blue - 56.0 / 255) < 0.0001)
        let platform = PomodoroughTheme.platformSRGB
        #expect(abs(platform.red - 20.0 / 255) < 0.0001)
        #expect(abs(platform.green - 44.0 / 255) < 0.0001)
        #expect(abs(platform.blue - 92.0 / 255) < 0.0001)
        let deep = PomodoroughTheme.platformDeepSRGB
        #expect(abs(deep.red - 12.0 / 255) < 0.0001)
        #expect(abs(deep.green - 27.0 / 255) < 0.0001)
        #expect(abs(deep.blue - 57.0 / 255) < 0.0001)
        let steel = PomodoroughTheme.steelSRGB
        #expect(abs(steel.red - 143.0 / 255) < 0.0001)
        #expect(abs(steel.green - 168.0 / 255) < 0.0001)
        #expect(abs(steel.blue - 184.0 / 255) < 0.0001)
    }

    @Test func landscapeCardHeightKeepsShortScreensUsable() {
        #expect(TimerScreen.landscapeCardHeight(for: CGSize(width: 667, height: 375)) == 275)
        #expect(TimerScreen.landscapeCardHeight(for: CGSize(width: 800, height: 200)) == 220)
        #expect(TimerScreen.landscapeCardHeight(for: CGSize(width: 932, height: 430)) == 330)
    }

    @Test func landscapeColumnWidensOnNarrowCards() {
        let narrow = TimerScreen.landscapeColumnWidth(for: 667)
        #expect(narrow != nil)
        #expect(abs(narrow! - 667 * 0.42) < 0.01)
        #expect(narrow! > 667 / 3)
    }

    @Test func landscapeColumnKeepsThirdOnWideCards() {
        #expect(abs(TimerScreen.landscapeColumnWidth(for: 844)! - 844 / 3) < 0.01)
        #expect(abs(TimerScreen.landscapeColumnWidth(for: 700)! - 700 / 3) < 0.01)
        #expect(TimerScreen.landscapeColumnWidth(for: 0) == nil)
        #expect(TimerScreen.landscapeColumnWidth(for: -5) == nil)
    }

    @Test func durationRowStacksOnlyAtAccessibilitySizes() {
        #expect(!DurationRow.shouldStackDurations(for: .large))
        #expect(!DurationRow.shouldStackDurations(for: .xxxLarge))
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            #expect(DurationRow.shouldStackDurations(for: size))
        }
    }

    @Test func historyEmptySpacingFollowsHeight() {
        #expect(HistoryScreen.emptyTopPadding(forHeight: 800) == 96)
        #expect(HistoryScreen.emptyTopPadding(forHeight: 300) == 36)
        #expect(HistoryScreen.emptyTopPadding(forHeight: 100) == 24)
        #expect(HistoryScreen.emptyTopPadding(forHeight: 0) == 24)
        #expect(HistoryScreen.emptyTopPadding(forHeight: -5) == 24)
        #expect(HistoryScreen.emptyTopPadding(forHeight: 2000) == 120)
    }

    @Test func clockMarkRingsStayProportional() {
        #expect(abs(RouteClockMark.outerLineWidth(forDiameter: 88) - 3.96) < 0.01)
        #expect(abs(RouteClockMark.outerLineWidth(forDiameter: 44) - 1.98) < 0.01)
        #expect(abs(RouteClockMark.innerLineWidth(forDiameter: 88) - 7.92) < 0.01)
        #expect(abs(RouteClockMark.ringPadding(forDiameter: 88) - 7.92) < 0.01)
        #expect(RouteClockMark.regularBaseDiameter == 88)
        #expect(RouteClockMark.compactBaseDiameter == 44)
    }

    @Test func backdropScalesWithContainer() {
        let phone = CGSize(width: 390, height: 844)
        #expect(abs(TimerBackdrop.glowDiameter(for: phone) - 273) < 0.01)
        let glowOffset = TimerBackdrop.glowOffset(for: phone)
        #expect(abs(glowOffset.width - -148.2) < 0.01)
        #expect(abs(glowOffset.height - -219.44) < 0.01)
        let band = TimerBackdrop.bandSize(for: phone)
        #expect(abs(band.width - 358.8) < 0.01)
        #expect(abs(band.height - 151.92) < 0.01)
        let bandOffset = TimerBackdrop.bandOffset(for: phone)
        #expect(abs(bandOffset.width - 171.6) < 0.01)
        #expect(abs(bandOffset.height - 261.64) < 0.01)
    }

    @Test func backdropNeverCollapsesOrExplodes() {
        let wide = CGSize(width: 1400, height: 900)
        #expect(TimerBackdrop.glowDiameter(for: wide) > TimerBackdrop.glowDiameter(for: CGSize(width: 390, height: 844)))
        #expect(TimerBackdrop.glowDiameter(for: .zero) == 0)
        #expect(TimerBackdrop.bandSize(for: .zero).width == 0)
        #expect(TimerBackdrop.bandSize(for: .zero).height == 120)
    }
}

// Pins the AP116 decision: the prominent Start/Pause/Resume label must
// clear WCAG AA 4.5:1 on every phase tint in both appearances. White
// reached only ~2.9:1 on signal red and ~1.5-1.6:1 on mint/ticket in dark
// mode, so the shipped label is black (7.0/13.5/14.1:1).
@Suite("Prominent button contrast")
struct ProminentButtonContrastTests {
    @Test(arguments: [TimerPhase.focus, .shortBreak, .longBreak])
    func prominentLabelClearsAAOnPhaseTintInBothAppearances(phase: TimerPhase) {
        for appearance in [PomodoroughTheme.Appearance.light, .dark] {
            let label = PomodoroughTheme.prominentLabelSRGB(for: appearance)
            let tint = PomodoroughTheme.accentSRGB(for: phase)
            let labelLuminance = PomodoroughTheme.relativeLuminance(red: label.red, green: label.green, blue: label.blue)
            let tintLuminance = PomodoroughTheme.relativeLuminance(red: tint.red, green: tint.green, blue: tint.blue)
            let ratio = PomodoroughTheme.contrastRatio(
                lighter: max(labelLuminance, tintLuminance),
                darker: min(labelLuminance, tintLuminance)
            )
            #expect(ratio >= 4.5)
        }
    }

    @Test func auditSourceMatchesShippedAccentColors() {
        #expect(PomodoroughTheme.accentSRGB(for: .focus) == PomodoroughTheme.signalSRGB)
        #expect(PomodoroughTheme.accentSRGB(for: .shortBreak) == PomodoroughTheme.mintSRGB)
        #expect(PomodoroughTheme.accentSRGB(for: .longBreak) == PomodoroughTheme.ticketSRGB)
    }
}
