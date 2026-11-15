import SwiftUI

/// Your spiral-and-rise motion, rendered above the message card.
struct ParticleCanvasView: View {
    let movementDuration: Double
    let particleCount: Int
    // State keeps random seeds stable across SwiftUI body updates.
    @State private var startingParticleOffsets: [CGFloat]
    @State private var startingParticleAlphas: [CGFloat]
    @State private var isSpark: [Bool]
    @State private var startDate = Date()

    init(particleCount: Int = 200, movementDuration: Double = 3.0) {
        let count = max(0, particleCount)
        self.particleCount = count
        self.movementDuration = max(0.1, movementDuration)
        _startingParticleOffsets = State(initialValue: (0..<count).map { _ in CGFloat.random(in: 0...1) })
        _startingParticleAlphas = State(initialValue: (0..<count).map { _ in CGFloat.random(in: 0...(CGFloat.pi * 2)) })
        _isSpark = State(initialValue: (0..<count).map { _ in Double.random(in: 0..<1) < 0.4 })
    }

    func particlePositionAndAlpha(index: Int, timeInterval: Double, canvasSize: CGSize) -> (CGPoint, CGFloat) {
        let startingRotation = startingParticleAlphas[index]
        let startingTimeOffset = Double(startingParticleOffsets[index]) * movementDuration
        let time = CGFloat((timeInterval + startingTimeOffset)
            .truncatingRemainder(dividingBy: movementDuration) / movementDuration)
        let rotations: CGFloat = 1.5
        let amplitude: CGFloat = 0.1 + 0.8 * (1 - time)
        let x = canvasSize.width / 2
            + cos(rotations * time * .pi * 2 + startingRotation)
            * canvasSize.width / 2 * amplitude * 0.8
        let y = (1 - time * time) * canvasSize.height
        let alpha: CGFloat = time < 0.3 ? 0 : 2 * (1 - time)
        return (CGPoint(x: x, y: y), alpha)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startDate))
            Canvas { context, size in
                guard let glow = context.resolveSymbol(id: 0),
                      let spark = context.resolveSymbol(id: 1) else { return }
                let fadeOutDuration = 1.0
                let remainingFade = min(1, max(0, (movementDuration - elapsed) / fadeOutDuration))
                let fadeOutOpacity = pow(remainingFade, 1.415)
                let envelope = min(1, elapsed / 0.12) * fadeOutOpacity
                for index in 0..<particleCount {
                    let (position, alpha) = particlePositionAndAlpha(index: index, timeInterval: elapsed, canvasSize: size)
                    context.opacity = Double(alpha) * envelope
                    context.draw(isSpark[index] ? spark : glow, at: position, anchor: .center)
                }
            } symbols: {
                SingleParticleView().tag(0)
                SparkParticleView().tag(1)
            }
        }
    }
}

struct SparkParticleView: View {
    var body: some View {
        Circle().fill(Color.purple)
            .frame(width: 3, height: 3)
            .blendMode(.plusLighter)
            .blur(radius: 1)
    }
}

struct SingleParticleView: View {
    var body: some View {
        Circle().fill(Color.purple.opacity(0.4))
            .frame(width:35, height:35)
            .blendMode(.plusLighter)
            .blur(radius: 10)
    }
}
