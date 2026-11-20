#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Pomodorough

// IOS18-06: at 375 pt "Join another room" wrapped onto two lines beside
// "Leave room". When the pair does not fit on one row, the buttons must
// stack, each label on one line, instead of wrapping inside the row.
@MainActor
@Suite("Room membership actions layout")
struct RoomMembershipActionsLayoutTests {
    @Test func narrowRowStacksTheButtonsInsteadOfWrappingALabel() {
        let actions = RoomMembershipActions(canLeave: true, isLeaving: false, join: {}, leave: {})
            .environment(\.dynamicTypeSize, .large)
        let host = UIHostingController(rootView: actions)
        let unbounded = CGFloat.greatestFiniteMagnitude
        let oneRow = host.sizeThatFits(in: CGSize(width: unbounded, height: unbounded))
        let narrow = host.sizeThatFits(in: CGSize(width: oneRow.width * 0.9, height: unbounded))
        // A wrapped row adds one text line to a single row of buttons; a
        // stack holds two full button rows.
        #expect(narrow.height >= oneRow.height * 2, "one row \(oneRow), narrow \(narrow)")
    }

    /// Accessibility sizes stack even when a row would fit. With no width
    /// limit a row is one button tall; a stack holds a second button below
    /// the first, and the two labels differ, so the bound leaves margin.
    @Test(arguments: [DynamicTypeSize.accessibility1, .accessibility5])
    func accessibilitySizesStackWhenARowWouldFit(size: DynamicTypeSize) {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let joinOnly = RoomMembershipActions(canLeave: false, isLeaving: false, join: {}, leave: {})
            .environment(\.dynamicTypeSize, size)
        let pair = RoomMembershipActions(canLeave: true, isLeaving: false, join: {}, leave: {})
            .environment(\.dynamicTypeSize, size)
        let oneButton = UIHostingController(rootView: joinOnly).sizeThatFits(in: unbounded)
        let stack = UIHostingController(rootView: pair).sizeThatFits(in: unbounded)
        #expect(stack.height > oneButton.height * 1.5, "one button \(oneButton), pair \(stack)")
    }

    @Test func wideRowKeepsBothButtonsOnOneLine() {
        let actions = RoomMembershipActions(canLeave: true, isLeaving: false, join: {}, leave: {})
            .environment(\.dynamicTypeSize, .large)
        let host = UIHostingController(rootView: actions)
        let unbounded = CGFloat.greatestFiniteMagnitude
        let oneRow = host.sizeThatFits(in: CGSize(width: unbounded, height: unbounded))
        let wide = host.sizeThatFits(in: CGSize(width: oneRow.width * 1.5, height: unbounded))
        #expect(wide.height == oneRow.height)
    }
}
#endif
