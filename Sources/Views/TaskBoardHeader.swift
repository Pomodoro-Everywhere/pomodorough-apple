import SwiftUI

struct TaskBoardHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    var body: some View {
        if showsColumns {
            HStack(spacing: TaskBoardColumns.spacing) {
                Text("TASK")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("FINISHED")
                    .containerRelativeFrame(
                        .horizontal,
                        count: TaskBoardColumns.totalSpans,
                        span: TaskBoardColumns.finishedSpan,
                        spacing: TaskBoardColumns.spacing,
                        alignment: .center
                    )
                Text("TIME")
                    .containerRelativeFrame(
                        .horizontal,
                        count: TaskBoardColumns.totalSpans,
                        span: TaskBoardColumns.timeSpan,
                        spacing: TaskBoardColumns.spacing,
                        alignment: .center
                    )
                Text("ACTION")
                    .containerRelativeFrame(
                        .horizontal,
                        count: TaskBoardColumns.totalSpans,
                        span: TaskBoardColumns.actionSpan,
                        spacing: TaskBoardColumns.spacing,
                        alignment: .center
                    )
            }
            .font(.caption2.monospaced().bold())
            .foregroundStyle(PomodoroughTheme.sky)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .background(PomodoroughTheme.track)
            .accessibilityHidden(true)
        }
    }

    private var showsColumns: Bool {
#if os(iOS)
        !dynamicTypeSize.isAccessibilitySize && horizontalSizeClass != .compact
#else
        !dynamicTypeSize.isAccessibilitySize
#endif
    }
}

/// Shared proportional column definition for the task board header and
/// rows. Spans are hundredths of the container width, so both views scale
/// together across phone, split-view, and iPad widths with no
/// fixed-point columns. Spacing matches the row/header HStack spacing.
enum TaskBoardColumns {
    static let spacing: CGFloat = 10
    static let totalSpans = 100
    static let finishedSpan = 17
    static let timeSpan = 19
    static let actionSpan = 13

    static var finishedFraction: CGFloat {
        CGFloat(finishedSpan) / CGFloat(totalSpans)
    }

    static var timeFraction: CGFloat {
        CGFloat(timeSpan) / CGFloat(totalSpans)
    }

    static var actionFraction: CGFloat {
        CGFloat(actionSpan) / CGFloat(totalSpans)
    }

    struct Widths: Equatable {
        let finished: CGFloat
        let time: CGFloat
        let action: CGFloat
    }

    static func widths(for totalWidth: CGFloat) -> Widths {
        guard totalWidth > 0 else { return Widths(finished: 0, time: 0, action: 0) }
        return Widths(
            finished: totalWidth * finishedFraction,
            time: totalWidth * timeFraction,
            action: totalWidth * actionFraction
        )
    }
}

#if DEBUG
#Preview {
    TaskBoardHeader()
}
#endif
