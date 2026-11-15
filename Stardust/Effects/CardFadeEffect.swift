import SwiftUI

/// Where the fire is. The card shader, the particle placement and the ash all read this,
/// so they stay one effect.
enum CardBurn {
    /// The card is gone by this progress; the remainder is the fire dying with the particles.
    static let burnEnd: CGFloat = 0.8
    /// Overscan so the scorch band is off the card at 0 and the ragged edge is off it at burnEnd.
    static let startMargin: CGFloat = 56
    static let endMargin: CGFloat = 30
    /// Must match the constant in Burn.metal.
    static let bulgeHeight: CGFloat = 22
    static let ignition: CGFloat = 1.35

    static func frontY(progress: CGFloat, height: CGFloat) -> CGFloat {
        let u = min(1, max(0, progress) / burnEnd)
        return height + startMargin - (height + startMargin + endMargin) * pow(u, ignition)
    }

    /// The centre burns ahead of the corners, like the swirl's funnel.
    static func bulge(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return bulgeHeight * sin(min(1, max(0, x / width)) * .pi)
    }

    /// Progress at which the front passes the point (x, y) in card coordinates.
    static func progress(reaching point: CGPoint, in size: CGSize) -> CGFloat {
        let travelled = size.height + startMargin - (point.y + bulge(x: point.x, width: size.width))
        let u = min(1, max(0, travelled / (size.height + startMargin + endMargin)))
        return pow(u, 1 / ignition) * burnEnd
    }
}

/// Burns a card away from the bottom up: scorch, char, then a purple ember rim.
/// Apply before the particle overlay so the particles remain visible.
struct CardFadeEffect: AnimatableModifier {
    var progress: CGFloat
    var size: CGSize
    var reduceMotion = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(1 - progress)
        } else {
            let progress = min(1, max(0, progress))
            content.layerEffect(
                ShaderLibrary.burn(
                    .float2(size),
                    .float(CardBurn.frontY(progress: progress, height: size.height)),
                    .float(progress)
                ),
                maxSampleOffset: CGSize(width: 4, height: 4),
                isEnabled: progress > 0
            )
        }
    }
}

/// Keeps the particle canvas's emission line on the burn front.
struct BurnTrackingOffset: AnimatableModifier {
    var progress: CGFloat
    let cardHeight: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Particles first show at 91% of their canvas height (alpha switches on at t = 0.3).
        let line = min(liftY(cardHeight: cardHeight) - 10, cardHeight - 4)
        content.offset(y: line - cardHeight * 0.91)
    }

    /// Follows the burn front, then keeps the fire rising and speeding up past the card's top
    /// so it drifts off the screen as it fades instead of stalling there.
    private func liftY(cardHeight: CGFloat) -> CGFloat {
        let end = CardBurn.burnEnd
        guard progress > end else {
            return CardBurn.frontY(progress: progress, height: cardHeight)
        }
        let travel = cardHeight + CardBurn.startMargin + CardBurn.endMargin
        // The front's speed at burnEnd, so the hand-off has no kink.
        let speed = travel * CardBurn.ignition / end
        let t = progress - end
        return CardBurn.frontY(progress: end, height: cardHeight) - speed * t - speed * 5 * t * t
    }
}
