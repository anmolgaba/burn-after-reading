import SwiftUI

/// Ash shed by the burn front: flakes flutter down and heap along the bottom of the stage.
struct AshFallView: View {
    /// The card's frame in this view's coordinate space.
    let cardFrame: CGRect
    let start: Date
    let duration: Double
    let reduceMotion: Bool
    /// Set when the heap is tapped: the ash blows away before the stage resets.
    let sweepStart: Date?
    @State private var isSettled = false

    static let sweepDuration = 0.4
    private static let flakeCount = 220
    private static let pileHeightMax: CGFloat = 38
    private static let ember = (red: 0.78, green: 0.50, blue: 0.95)

    var body: some View {
        TimelineView(.animation(paused: isSettled && sweepStart == nil)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(start))
            let sweep = sweepStart.map { min(1, max(0, timeline.date.timeIntervalSince($0) / Self.sweepDuration)) } ?? 0
            Canvas { context, size in
                draw(in: &context, size: size, elapsed: elapsed, sweep: CGFloat(sweep))
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

    private struct Falling {
        var index: Int
        var x0: CGFloat
        var yLocal: CGFloat
        var age: Double
        var fallDuration: Double
        var k: CGFloat
    }

    private func random(_ index: Int, _ salt: UInt64) -> CGFloat {
        StableRandom.unit(index, salt: salt)
    }

    /// Value noise along x, so the heap is lumpy rather than a smooth mound.
    private func lump(_ x: CGFloat) -> CGFloat {
        let cell = floor(x / 16)
        let t = x / 16 - cell
        let a = random(Int(cell), 71)
        let b = random(Int(cell) + 1, 71)
        return a + (b - a) * t * t * (3 - 2 * t)
    }

    private func pileHeight(_ x: CGFloat) -> CGFloat {
        let spread = (x - cardFrame.midX) / (0.42 * cardFrame.width)
        return Self.pileHeightMax * exp(-spread * spread) * (0.82 + 0.36 * lump(x))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, elapsed: Double, sweep: CGFloat) {
        guard cardFrame.width > 0, cardFrame.height > 0 else { return }
        let fadeIn = reduceMotion ? min(1, elapsed / 0.3) : 1
        context.opacity = fadeIn * Double(1 - sweep)
        // The gust starts fast, as a response to the tap. Reduce Motion only fades.
        let blown = reduceMotion ? 0 : 1 - (1 - sweep) * (1 - sweep)

        var falling: [Falling] = []
        falling.reserveCapacity(Self.flakeCount)
        var landedCount = 0

        for index in 0..<Self.flakeCount {
            let x0 = cardFrame.minX + random(index, 1) * cardFrame.width
            let yLocal = cardFrame.height * (1 - pow(random(index, 2), 1.6))
            let birth = Double(CardBurn.progress(reaching: CGPoint(x: x0 - cardFrame.minX, y: yLocal),
                                                 in: cardFrame.size)) * duration
            let age: Double = reduceMotion ? .greatestFiniteMagnitude : elapsed - birth
            guard age >= 0 else { continue }
            let fallDuration = 0.9 + 0.9 * Double(random(index, 3))
            let k = CGFloat(min(1, age / fallDuration))
            if k >= 1 { landedCount += 1 }
            falling.append(Falling(index: index, x0: x0, yLocal: yLocal, age: age, fallDuration: fallDuration, k: k))
        }

        // The heap only ever stands as tall as the ash that has reached it, and every flake rests
        // inside that height, so nothing sits in the air above a half-grown heap.
        let grow = pow(CGFloat(landedCount) / CGFloat(Self.flakeCount), 0.8)
        let heap = grow * (1 - blown)

        if heap > 0.01 {
            let left = max(0, cardFrame.midX - 0.75 * cardFrame.width)
            let right = min(size.width, cardFrame.midX + 0.75 * cardFrame.width)
            var pile = Path()
            pile.move(to: CGPoint(x: left, y: size.height))
            var x = left
            while x < right {
                pile.addLine(to: CGPoint(x: x, y: size.height - pileHeight(x) * heap))
                x += 3
            }
            pile.addLine(to: CGPoint(x: right, y: size.height - pileHeight(right) * heap))
            pile.addLine(to: CGPoint(x: right, y: size.height))
            pile.closeSubpath()

            var dust = context
            dust.addFilter(.blur(radius: 4))
            dust.opacity = context.opacity * 0.25
            dust.fill(pile, with: .color(Color(white: 0.4)))

            let top = size.height - Self.pileHeightMax * 1.25 * heap
            context.fill(pile, with: .linearGradient(
                Gradient(colors: [Color(white: 0.34), Color(white: 0.16)]),
                startPoint: CGPoint(x: cardFrame.midX, y: top),
                endPoint: CGPoint(x: cardFrame.midX, y: size.height)))
        }

        for flake in falling {
            let index = flake.index
            let k = flake.k
            let settled = min(flake.age, flake.fallDuration)
            let landX = flake.x0 + (cardFrame.midX - flake.x0) * 0.35 + (random(index, 4) - 0.5) * 40
            let landY = size.height - pileHeight(landX) * grow * random(index, 5) - 1

            let startY = cardFrame.minY + flake.yLocal
            let y = startY + (landY - startY) * pow(k, 1.6)
            let sway = sin(CGFloat(settled) * (1.5 + 1.5 * random(index, 6)) * 2 * .pi
                           + random(index, 7) * 2 * .pi) * (6 + 8 * random(index, 8)) * (1 - k)
            let x = flake.x0 + (landX - flake.x0) * k + sway

            let width = 1.5 + 2.5 * random(index, 9)
            let rotation = Double(random(index, 11)) * .pi + settled * (1 + 3 * Double(random(index, 10)))

            var glow = reduceMotion ? 0 : max(0, 1 - flake.age / 0.4)
            if !reduceMotion, k >= 1, index % 23 == 0 {
                glow = max(glow, max(0, 1 - (flake.age - flake.fallDuration) / 1.5))
            }
            let grey = 0.16 + 0.16 * Double(random(index, 12))
            let color = Color(red: grey + 0.02 + (Self.ember.red - grey - 0.02) * glow,
                              green: grey + (Self.ember.green - grey) * glow,
                              blue: grey + (Self.ember.blue - grey) * glow)

            let position = CGPoint(x: x + blown * (50 + 110 * random(index, 13)),
                                   y: y - blown * (8 + 34 * random(index, 14)))
            var flakeContext = context
            flakeContext.translateBy(x: position.x, y: position.y)
            flakeContext.rotate(by: .radians(rotation))
            let rect = CGRect(x: -width / 2, y: -width * 0.3, width: width, height: width * 0.6)
            flakeContext.fill(Path(rect), with: .color(color.opacity(0.9)))
        }
    }
}
