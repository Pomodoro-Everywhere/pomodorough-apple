#if os(iOS)
import SwiftUI
import UIKit

/// One phase of a horizontal swipe. Travel is the negated horizontal
/// translation in points, the sign SwipeToDeleteMetrics.exposure takes.
enum HorizontalSwipeEvent: Equatable {
    case changed(travel: CGFloat)
    case ended(travel: CGFloat, projectedTravel: CGFloat)
    case cancelled
}

/// UIKit pan for a row swipe inside a vertical scroll view. It begins only
/// when the drag starts predominantly sideways, so a vertical drag fails it
/// at once and the scroll view keeps the touch. A SwiftUI DragGesture on the
/// row claims every drag on iOS 18 and later, which stopped the task board
/// from scrolling under a finger that landed on a row (R54-AU04).
struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    let onSwipe: (HorizontalSwipeEvent) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    // Window coordinates: the row's offset follows the finger, so its own
    // space would feed the exposure back into the translation.
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let travel = -recognizer.translation(in: nil).x
        switch recognizer.state {
        case .changed:
            onSwipe(.changed(travel: travel))
        case .ended:
            let velocity = -recognizer.velocity(in: nil).x
            onSwipe(.ended(
                travel: travel,
                projectedTravel: SwipeToDeleteMetrics.projectedTravel(travel: travel, velocity: velocity)
            ))
        case .cancelled:
            onSwipe(.cancelled)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: nil)
            return SwipeToDeleteMetrics.isHorizontal(CGSize(width: translation.x, height: translation.y))
        }
    }
}
#endif
