import SwiftUI

/// IOS27-08: the system style draws a row's value in translucent
/// `.secondary`, about 3.4:1 on a white card. This style keeps the system
/// layout and draws the value in the pinned secondary grey instead.
struct SecondaryValueLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            configuration.content
                .foregroundStyle(PomodoroughTheme.secondaryText)
        } label: {
            configuration.label
        }
        // The inner row uses the system style; this style would recurse.
        .labeledContentStyle(.automatic)
    }
}

extension LabeledContentStyle where Self == SecondaryValueLabeledContentStyle {
    static var secondaryValue: SecondaryValueLabeledContentStyle { SecondaryValueLabeledContentStyle() }
}
