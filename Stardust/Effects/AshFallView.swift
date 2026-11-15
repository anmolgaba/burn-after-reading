import SwiftUI

/// Ash shed by the burn front: flakes flutter down and heap along the bottom of the stage.
struct AshFallView: View {
    /// The card's frame in this view's coordinate space.
    let cardFrame: CGRect
    let start: Date
    let duration: Double
    let reduceMotion: Bool
    @State private var isSettled = false

    private static let flakeCount = 140
    private static let pileHeightMax: CGFloat = 14
    private static let ember = (red: 0.78, green: 0.50, blue: 0.95)

    var body: some View {
        TimelineView(.animation(paused: isSettled)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(start))
            Canvas { context, size in
                draw(in: &context, size: size, elapsed: elapsed)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            // Last flake: born by 0.8 × duration, falls ≤ 1.8 s, ember cools over 1.5 s.
            try? await Task.sleep(for: .seconds(duration + 3.5))
            isSettled = true
        }
    }

    private struct Flake {
        var position: CGPoint
        var size: CGSize
        var rotation: Double
        var color: Color
    }

    private func random(_ index: Int, _ salt: UInt64) -> CGFloat {
        StableRandom.unit(index, salt: salt)
    }

    /// Value noise along x, so the heap is lumpy rather than a smooth mound.
    private func lump(_ x: CGFloat) -> CGFloat {
        let cell = floor(x / 9)
        let t = x / 9 - cell
        let a = random(Int(cell), 71)
        let b = random(Int(cell) + 1, 71)
        return a + (b - a) * t
    }

    private func pileHeight(_ x: CGFloat) -> CGFloat {
        let spread = (x - cardFrame.midX) / (0.36 * cardFrame.width)
        return Self.pileHeightMax * exp(-spread * spread) * (0.75 + 0.5 * lump(x))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, elapsed: Double) {
        guard cardFrame.width > 0, cardFrame.height > 0 else { return }
        if reduceMotion {
            context.opacity = min(1, elapsed / 0.3)
        }

        var flakes: [Flake] = []
        flakes.reserveCapacity(Self.flakeCount)
        var landedCount = 0

        for index in 0..<Self.flakeCount {
            let x0 = cardFrame.minX + random(index, 1) * cardFrame.width
            let yLocal = cardFrame.height * (1 - pow(random(index, 2), 1.6))
            let birth = Double(CardBurn.progress(reaching: CGPoint(x: x0 - cardFrame.minX, y: yLocal),
                                                 in: cardFrame.size)) * duration
            let age = reduceMotion ? .greatestFiniteMagnitude : elapsed - birth
            guard age >= 0 else { continue }

            let fallDuration = 0.9 + 0.9 * Double(random(index, 3))
            let landX = x0 + (cardFrame.midX - x0) * 0.25 + (random(index, 4) - 0.5) * 40
            let landY = size.height - pileHeight(landX) * random(index, 5) - 1
            let k = CGFloat(min(1, age / fallDuration))
            if k >= 1 { landedCount += 1 }

            let startY = cardFrame.minY + yLocal
            let y = startY + (landY - startY) * pow(k, 1.6)
            let sway = sin(CGFloat(min(age, fallDuration)) * (1.5 + 1.5 * random(index, 6)) * 2 * .pi
                           + random(index, 7) * 2 * .pi) * (6 + 8 * random(index, 8)) * (1 - k)
            let x = x0 + (landX - x0) * k + sway

            let width = 1.5 + 2.5 * random(index, 9)
            let rotation = Double(random(index, 11)) * .pi
                + min(age, fallDuration) * (1 + 3 * Double(random(index, 10)))

            var glow = reduceMotion ? 0 : max(0, 1 - age / 0.4)
            if !reduceMotion, k >= 1, index % 23 == 0 {
                glow = max(glow, max(0, 1 - (age - fallDuration) / 1.5))
            }
            let grey = 0.16 + 0.16 * Double(random(index, 12))
            let color = Color(red: grey + 0.02 + (Self.ember.red - grey - 0.02) * glow,
                              green: grey + (Self.ember.green - grey) * glow,
                              blue: grey + (Self.ember.blue - grey) * glow)

            flakes.append(Flake(position: CGPoint(x: x, y: y),
                                size: CGSize(width: width, height: width * 0.6),
                                rotation: rotation,
                                color: color))
        }

        let landed = CGFloat(landedCount) / CGFloat(Self.flakeCount)
        if landed > 0 {
            let grow = pow(landed, 0.8)
            let left = cardFrame.midX - 0.6 * cardFrame.width
            let right = cardFrame.midX + 0.6 * cardFrame.width
            var pile = Path()
            pile.move(to: CGPoint(x: left, y: size.height))
            var x = left
            while x <= right {
                pile.addLine(to: CGPoint(x: x, y: size.height - pileHeight(x) * grow))
                x += 3
            }
            pile.addLine(to: CGPoint(x: right, y: size.height))
            pile.closeSubpath()

            var dust = context
            dust.addFilter(.blur(radius: 3))
            dust.opacity = context.opacity * 0.25
            dust.fill(pile, with: .color(Color(white: 0.4)))

            let top = size.height - Self.pileHeightMax * 1.25 * grow
            context.fill(pile, with: .linearGradient(
                Gradient(colors: [Color(white: 0.34), Color(white: 0.16)]),
                startPoint: CGPoint(x: cardFrame.midX, y: top),
                endPoint: CGPoint(x: cardFrame.midX, y: size.height)))
        }

        for flake in flakes {
            var flakeContext = context
            flakeContext.translateBy(x: flake.position.x, y: flake.position.y)
            flakeContext.rotate(by: .radians(flake.rotation))
            let rect = CGRect(x: -flake.size.width / 2, y: -flake.size.height / 2,
                              width: flake.size.width, height: flake.size.height)
            flakeContext.fill(Path(rect), with: .color(flake.color.opacity(0.9)))
        }
    }
}
