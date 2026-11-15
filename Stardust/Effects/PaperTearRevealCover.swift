import SwiftUI
import CoreText

/// A paper seal whose original top strip bends upward during a left-to-right tear.
struct PaperTearRevealCover: View {
    let size: CGSize
    let reduceMotion: Bool
    let messageDuration: Double
    let dropDistance: CGFloat
    let onRevealStarted: () -> Void
    let onRevealCompleted: () -> Void

    @Binding private var releaseProgress: CGFloat
    @State private var tearProgress: CGFloat = 0
    @State private var dragStartProgress: CGFloat?
    @State private var hasCommitted = false
    @State private var hasDetached = false
    @State private var isActive = false
    @Environment(\.displayScale) private var displayScale
    @GestureState private var isDragging = false
    /// Where the finger is along the seam while touching; drives the press tilt.
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.45, bounce: 0.3)))
    private var touchX: CGFloat?
    @State private var nudgeEpoch = Date()
    /// True only while the idle peel is on screen, so the timeline rests between lifts.
    @State private var isLifting = false
    @State private var throwScale: CGFloat = 1
    @State private var toothIndex = 0

    init(size: CGSize, reduceMotion: Bool, messageDuration: Double, releaseProgress: Binding<CGFloat>, dropDistance: CGFloat,
         onRevealStarted: @escaping () -> Void, onRevealCompleted: @escaping () -> Void) {
        self.size = size
        self.reduceMotion = reduceMotion
        self.messageDuration = messageDuration
        self.dropDistance = dropDistance
        self.onRevealStarted = onRevealStarted
        self.onRevealCompleted = onRevealCompleted
        _releaseProgress = releaseProgress
    }

    var body: some View {
        let travel = max(1, size.width)

        ZStack(alignment: .topLeading) {
            if reduceMotion {
                surface(progress: 0)
                    .modifier(PaperCastShadow())
                    .overlay(alignment: .topLeading) {
                        // No curl or throw: the cut advancing along the seam is the feedback.
                        paper.tornEdge(through: max(tearProgress * size.width, paper.notchDepth + 14))
                            .stroke(PaperTearArtwork.ink.opacity(0.8),
                                    style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                            .allowsHitTesting(false)
                    }
                    .opacity(Double(1 - releaseProgress))
            } else {
                TimelineView(.animation(paused: !(isNudging && isLifting))) { timeline in
                    let peel = isNudging && isLifting ? Self.peel(at: timeline.date.timeIntervalSince(nudgeEpoch)) : 0
                    ZStack(alignment: .topLeading) {
                        surface(progress: hasDetached ? 1 : tearProgress, peel: peel, part: .sheet)
                            .modifier(PaperCastShadow())
                            .modifier(PaperPieceRelease(progress: releaseProgress, part: .sheet,
                                                        width: size.width, dropDistance: dropDistance))
                        surface(progress: hasDetached ? 1 : tearProgress, peel: peel, part: .strip)
                            .modifier(PaperPieceRelease(progress: releaseProgress, part: .strip,
                                                        width: size.width, dropDistance: dropDistance,
                                                        throwScale: throwScale))
                    }
                }
            }

            // The whole flap is the handle, from just above its top edge to 22 pt below the seam.
            Color.clear
                .frame(width: size.width, height: paper.seamY + 38)
                .contentShape(Rectangle())
                .position(x: size.width / 2, y: (paper.seamY + 6) / 2)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("paperTearSurface"))
                        .updating($isDragging) { _, dragging, _ in dragging = true }
                        .updating($touchX) { value, x, _ in x = value.location.x }
                        .onChanged { value in
                            guard !hasCommitted else { return }
                            if dragStartProgress == nil {
                                // Pick up from wherever the idle peel has lifted the corner.
                                let peel = Self.peel(at: Date().timeIntervalSince(nudgeEpoch))
                                if !reduceMotion, isLifting, tearProgress == 0, peel > 0.004 { tearProgress = peel }
                            }
                            let start = dragStartProgress ?? tearProgress
                            dragStartProgress = start
                            // The tear front moves 1:1 with the finger, all the way to the far edge,
                            // and stays torn if it reverses or lifts.
                            tearProgress = max(tearProgress, min(1, start + value.translation.width / travel))
                            toothIndex = Int(tearProgress * size.width / 14)
                            if tearProgress >= 1 { finishTear(velocity: value.velocity.width / travel) }
                        }
                        .onEnded { value in
                            dragStartProgress = nil
                            guard !hasCommitted else { return }
                            // Letting go past the commit point finishes the tear; so does a rightward
                            // flick from a third of the way.
                            let momentum = (value.predictedEndTranslation.width - value.translation.width) / travel
                            if tearProgress >= Self.commitProgress
                                || (tearProgress > 0.33 && tearProgress + momentum >= Self.commitProgress) {
                                finishTear(velocity: value.velocity.width / travel)
                            }
                        }
                )
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "paperTearSurface")
        // Pressing on the seam tips the envelope away from the finger, like paper under a thumb.
        // Scoped so only the tilt springs; the tear itself stays locked to the finger.
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.72)) { content in
            content
                .rotation3DEffect(.degrees(pressTilt.pitch), axis: (x: 1, y: 0, z: 0),
                                  anchor: .center, perspective: 0.5)
                .rotation3DEffect(.degrees(pressTilt.yaw), axis: (x: 0, y: 1, z: 0),
                                  anchor: .center, perspective: 0.5)
        }
        .onAppear { isActive = true }
        .onDisappear { isActive = false }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { dragStartProgress = nil }
        }
        .task(id: isNudging) {
            guard isNudging else {
                isLifting = false
                return
            }
            // Re-read the clock every pass so the pauses never drift away from `peel(at:)`.
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(nudgeEpoch) - Self.nudgeDelay
                let phase = elapsed < 0 ? elapsed : elapsed.truncatingRemainder(dividingBy: Self.nudgePeriod)
                if phase >= 0, phase < Self.nudgeLength {
                    isLifting = true
                    try? await Task.sleep(for: .seconds(Self.nudgeLength - phase + 0.05))
                } else {
                    isLifting = false
                    try? await Task.sleep(for: .seconds(phase < 0 ? -phase : Self.nudgePeriod - phase))
                }
            }
        }
        // One tick for every two perforation teeth, then a thud as the strip comes away.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: toothIndex)
        .sensoryFeedback(.impact(weight: .medium), trigger: hasDetached)
        .allowsHitTesting(!hasCommitted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidential letter from janvi kapoor. Read once.")
        .accessibilityValue("\(Int(tearProgress * 100)) percent torn")
        .accessibilityHint("Swipe right along the tear line. The revealed message begins disappearing after \(Int(messageDuration)) seconds.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("paperTearReveal")
        .accessibilityHidden(hasCommitted)
        .accessibilityAction { finishTear() }
        .accessibilityAction(named: Text("Reveal message")) { finishTear() }
    }

    private var paper: PaperTearArtwork { EnvelopeCache.paper(for: size) }

    /// Subtle: at most about 3° across and 2.5° back, and only while a finger is down.
    private var pressTilt: (pitch: Double, yaw: Double) {
        guard !reduceMotion, !hasCommitted, let touchX else { return (0, 0) }
        let across = Double(min(1, max(0, touchX / size.width)) - 0.5)
        return (2.5, across * 6)
    }

    private var isNudging: Bool {
        !reduceMotion && !hasCommitted && tearProgress == 0 && !isDragging
    }

    /// Every 4 s (first after 1.4 s) the loose corner at the notch lifts about 14 pt and settles,
    /// hinting where to start tearing.
    private static let nudgePeriod = 4.0
    private static let nudgeDelay = 1.4
    private static let nudgeLength = 1.1

    private static func peel(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed > nudgeDelay else { return 0 }
        let phase = (elapsed - nudgeDelay).truncatingRemainder(dividingBy: nudgePeriod)
        guard phase < nudgeLength else { return 0 }
        let lift = sin(.pi * phase / nudgeLength)
        return CGFloat(0.045 * lift * lift)
    }

    private func surface(progress: CGFloat, peel: CGFloat = 0, part: PaperPart = .whole) -> some View {
        let padding = TornPaperSurface.shadowPadding
        let envelope = EnvelopeCache.image(for: size, scale: displayScale, seconds: Int(messageDuration.rounded(.up)))
        return TornPaperSurface(paper: paper, envelope: envelope,
                                tearProgress: progress, peel: peel, reduceMotion: reduceMotion, part: part)
            .frame(width: size.width + padding * 2, height: size.height + paper.headroom + padding)
            .offset(x: -padding, y: -paper.headroom)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private static let commitProgress: CGFloat = 0.85

    /// `velocity` is the finger's speed along the seam in card widths per second.
    private func finishTear(velocity: CGFloat = 0) {
        guard !hasCommitted else { return }
        hasCommitted = true
        onRevealStarted()
        // A hard flick throws the strip further than a slow tear.
        throwScale = min(1.5, max(0.8, 0.8 + velocity * 0.25))
        let remaining = 1 - tearProgress
        guard !reduceMotion, remaining > 0.001 else {
            tearProgress = 1
            releasePaper()
            return
        }
        // The spring starts at the finger's speed, so there is no seam between drag and finish.
        // Its initial velocity is relative to the distance left.
        let relativeVelocity = min(30, Double(max(0, velocity) / remaining))
        withAnimation(.interpolatingSpring(duration: 0.12 + Double(remaining) * 0.5, bounce: 0,
                                           initialVelocity: relativeVelocity),
                      completionCriteria: .logicallyComplete) {
            tearProgress = 1
        } completion: {
            releasePaper()
        }
    }

    private func releasePaper() {
        guard isActive, !hasDetached else { return }
        var detach = Transaction()
        detach.disablesAnimations = true
        withTransaction(detach) {
            hasDetached = true
        }
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.2)
            : .linear(duration: PaperReleaseMotion.duration)
        withAnimation(animation, completionCriteria: .removed) {
            releaseProgress = 1
        } completion: {
            guard isActive else { return }
            onRevealCompleted()
        }
    }
}

/// The same soft cast shadow as the letter card.
private struct PaperCastShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.07), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.055), radius: 12, x: 0, y: 7)
    }
}

private enum PaperPart {
    case whole, sheet, strip
}

/// Per-frame tear rendering. The static envelope is a cached bitmap that is only re-masked
/// along the tear; the Canvas draws just the lifted strip and the sheet's fringe.
private struct TornPaperSurface: View, Animatable {
    static let shadowPadding: CGFloat = 16

    let paper: PaperTearArtwork
    let envelope: Image
    var tearProgress: CGFloat
    /// The idle nudge: the strip's corner lifts loose from the notch without tearing further.
    var peel: CGFloat = 0
    let reduceMotion: Bool
    var part: PaperPart = .whole

    var animatableData: CGFloat {
        get { tearProgress }
        set { tearProgress = newValue }
    }

    var body: some View {
        let tear = reduceMotion ? 0 : min(1, max(0, tearProgress))
        let front = max(tear, peel) * paper.size.width
        // A peel curls the short loose corner fully; a real tear bends gradually with progress.
        let curlProgress = peel > tear ? 1 : tear
        ZStack(alignment: .topLeading) {
            if part != .strip {
                envelope
                    .resizable()
                    .frame(width: paper.size.width, height: paper.size.height)
                    .mask(alignment: .topLeading) { paper.remainingSheet(through: front) }
                    .offset(x: Self.shadowPadding, y: paper.headroom)
            }
            if front > 0.5 {
                Canvas { context, _ in
                    context.translateBy(x: Self.shadowPadding, y: paper.headroom)
                    if part != .strip {
                        context.stroke(paper.fibers(through: front), with: .color(PaperTearArtwork.fiberColor),
                                       lineWidth: 0.45)
                    }
                    if part != .sheet {
                        drawStrip(in: context, front: front, curlProgress: curlProgress)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawStrip(in context: GraphicsContext, front: CGFloat, curlProgress: CGFloat) {
        let curl = PaperCurl(front: front, progress: curlProgress)
        // The strip is cut from the same bitmap as the flap, so its shading matches at the tear front.
        let texture = context.resolve(envelope)
        var lifted = context
        lifted.clip(to: Path(CGRect(x: -Self.shadowPadding, y: -paper.headroom,
                                    width: front + Self.shadowPadding,
                                    height: paper.size.height + paper.headroom + Self.shadowPadding)))
        lifted.addFilter(.shadow(color: PaperTearArtwork.ink.opacity(0.16), radius: 3, x: 0, y: 3))
        lifted.drawLayer { strip in
            let outline = paper.strip(through: front, curl: curl)
            var surface = strip
            surface.clip(to: outline)
            // Small affine slices carry the grain around the bend.
            for x in stride(from: CGFloat(0), to: front, by: 12) {
                let width = min(12, front - x)
                var slice = surface
                slice.concatenate(curl.transform(at: x + width / 2))
                slice.clip(to: Path(CGRect(x: x, y: -2, width: width + 0.5, height: paper.seamY + 6)))
                slice.draw(texture, in: paper.textureRect)
            }
            let edge = paper.tornEdge(through: front, curl: curl)
            var lip = strip
            lip.translateBy(x: 0, y: -1)
            lip.addFilter(.blur(radius: 0.9))
            lip.stroke(edge, with: .color(PaperTearArtwork.ink.opacity(0.28)), lineWidth: 1.2)
            strip.stroke(edge, with: .color(.white.opacity(0.6)), lineWidth: 1)
            strip.stroke(paper.fibers(through: front, curl: curl),
                         with: .color(PaperTearArtwork.fiberColor), lineWidth: 0.45)
        }
    }
}

/// The parts of the envelope that never change during a tear, drawn once per size.
private struct EnvelopeArtwork: View {
    let paper: PaperTearArtwork
    let seconds: Int

    var body: some View {
        Canvas { context, _ in
            context.draw(context.resolve(PaperMaterial.image), in: paper.textureRect)
            paper.drawFlap(in: context)
            paper.drawAddress(in: context)
            paper.drawReadOnce(in: context, seconds: seconds)
        }
        .frame(width: paper.size.width, height: paper.size.height)
    }
}

/// One envelope per card size: geometry plus its pre-rendered static bitmap.
@MainActor
private enum EnvelopeCache {
    private static var entry: (key: String, paper: PaperTearArtwork, image: Image?, imageKey: String?)?

    static func paper(for size: CGSize) -> PaperTearArtwork {
        let key = "\(size.width)x\(size.height)"
        if let entry, entry.key == key { return entry.paper }
        let paper = PaperTearArtwork(size: size)
        entry = (key, paper, nil, nil)
        return paper
    }

    /// The read-once stamp prints the reading time, so the bitmap is keyed by it too.
    static func image(for size: CGSize, scale: CGFloat, seconds: Int) -> Image {
        let paper = paper(for: size)
        let imageKey = "\(scale)|\(seconds)"
        if let image = entry?.image, entry?.imageKey == imageKey { return image }
        let renderer = ImageRenderer(content: EnvelopeArtwork(paper: paper, seconds: seconds))
        renderer.scale = scale
        let image = renderer.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "envelope")
        entry?.image = image
        entry?.imageKey = imageKey
        return image
    }
}

extension PaperTearArtwork {
    var scale: CGFloat { size.width / 320 }

    static func shadeFlap(in context: GraphicsContext, path: Path, start: CGPoint, end: CGPoint) {
        context.fill(path, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.27), location: 0),
                             .init(color: .white.opacity(0.12), location: 0.10),
                             .init(color: .white.opacity(0.08), location: 0.68),
                             .init(color: ink.opacity(0.13), location: 1)]),
            startPoint: start, endPoint: end))
    }

    /// The flap, its fold shading, and the soft shadow and highlight along the zigzag.
    /// When torn, the mask keeps the part of this edge treatment below the tear as the sheet's lip.
    func drawFlap(in context: GraphicsContext) {
        let flap = flap(from: 0)
        let edge = guide(from: 0)
        var shadow = context
        shadow.translateBy(x: 0, y: 1.3)
        shadow.addFilter(.blur(radius: 1.1))
        shadow.stroke(edge, with: .color(Self.ink.opacity(0.34)), lineWidth: 1.6)
        Self.shadeFlap(in: context, path: flap, start: .zero, end: CGPoint(x: 0, y: seamY))
        context.stroke(edge, with: .color(.white.opacity(0.7)), lineWidth: 0.7)
        // The notch's cut faces get the same pale core so the V reads as a clean cut.
        context.stroke(notchOutline, with: .color(Self.ink.opacity(0.25)), lineWidth: 0.8)
    }

    func drawAddress(in context: GraphicsContext) {
        let ink = Color(white: 0.16)
        let left = size.width * 0.065

        // Sender, top left under the flap; the name sits on its own underline.
        let fontSize = 15 * scale
        let font = PaperTypography.font(size: fontSize)
        let measure = PaperTypography.uiFont(size: fontSize)
        let labelWidth = ("From: " as NSString).size(withAttributes: [.font: measure]).width
        let nameWidth = ("janvi kapoor" as NSString).size(withAttributes: [.font: measure]).width
        let top = seamY + 22 * scale
        context.draw(Text("From:").font(font).foregroundColor(ink), at: CGPoint(x: left, y: top), anchor: .topLeading)
        context.draw(Text("janvi kapoor").font(font).foregroundColor(ink),
                     at: CGPoint(x: left + labelWidth + 6 * scale, y: top), anchor: .topLeading)
        let ruleY = top + measure.ascender + 5 * scale
        let rule = Path { path in
            path.move(to: CGPoint(x: left + labelWidth, y: ruleY))
            path.addLine(to: CGPoint(x: left + labelWidth + nameWidth + 14 * scale, y: ruleY))
        }
        context.stroke(rule, with: .color(ink.opacity(0.35)), lineWidth: 0.7 * scale)

        // Postage, top right.
        let stamp = size.width * 0.15
        PostalMarks.drawCorner(in: context,
                               stampCenter: CGPoint(x: size.width - stamp * 0.95, y: seamY + 20 * scale + stamp * 0.6),
                               size: stamp)

        let bandTop = size.height - 7 * scale
        drawConfidential(in: context, center: CGPoint(x: size.width / 2, y: seamY + (bandTop - seamY) * 0.52))
        drawAirmailBand(in: context, top: bandTop)
    }

    /// A handwritten note above the airmail band, in the sender's ink, so the reader learns
    /// the letter can be read once before they open it.
    func drawReadOnce(in context: GraphicsContext, seconds: Int) {
        let note = "read once, vanishes \(seconds)s after opening"
        let left = size.width * 0.065
        let available = size.width - left * 2
        var fontSize = 14 * scale
        let natural = (note as NSString).size(withAttributes: [.font: PaperTypography.uiFont(size: fontSize)]).width
        if natural > available { fontSize *= available / natural }
        context.draw(Text(note)
            .font(PaperTypography.font(size: fontSize))
            .foregroundColor(Color(white: 0.16)),
            at: CGPoint(x: left, y: size.height - 7 * scale - 14 * scale), anchor: .bottomLeading)
    }

    private func drawConfidential(in context: GraphicsContext, center: CGPoint) {
        var stamp = context
        stamp.translateBy(x: center.x, y: center.y)
        stamp.rotate(by: .degrees(-7))
        let scale = size.width * 0.78 / ConfidentialStamp.width
        stamp.scaleBy(x: scale, y: scale)
        stamp.translateBy(x: -ConfidentialStamp.width / 2, y: -ConfidentialStamp.height / 2)
        stamp.blendMode = .multiply
        stamp.drawLayer { ink in
            ink.fill(ConfidentialStamp.shared.outline,
                     with: .color(Color(red: 0.72, green: 0.14, blue: 0.075).opacity(0.88)))
            ink.blendMode = .destinationOut
            ink.fill(ConfidentialStamp.shared.wear, with: .color(.white))
        }
    }

    private func drawAirmailBand(in context: GraphicsContext, top: CGFloat) {
        let height = size.height - top
        let stripe = 9 * scale, gap = 5 * scale
        var band = context
        band.clip(to: Path(CGRect(x: 0, y: top, width: size.width, height: height)))
        var red = Path(), blue = Path()
        var x = -height
        var index = 0
        while x < size.width + height {
            let piece = Path { path in
                path.move(to: CGPoint(x: x + height, y: top))
                path.addLine(to: CGPoint(x: x + height + stripe, y: top))
                path.addLine(to: CGPoint(x: x + stripe, y: top + height))
                path.addLine(to: CGPoint(x: x, y: top + height))
                path.closeSubpath()
            }
            if index.isMultiple(of: 2) { red.addPath(piece) } else { blue.addPath(piece) }
            x += stripe + gap
            index += 1
        }
        band.blendMode = .multiply
        band.fill(red, with: .color(PostalMarks.red.opacity(0.85)))
        band.fill(blue, with: .color(PostalMarks.blue.opacity(0.85)))
    }
}

/// The card and both paper pieces sample the same clock, after detachment.
private enum PaperReleaseMotion {
    struct Pose {
        var stripX: CGFloat = 0
        var stripY: CGFloat = 0
        var stripAngle = 0.0
        var stripOpacity = 1.0
        var sheetKick: CGFloat = 0
        var sheetFall: CGFloat = 0
        var sheetAngle = 0.0
        var messageY: CGFloat = 32
        var messageOpacity = 0.0
    }

    static let timeline = KeyframeTimeline(initialValue: Pose()) {
        KeyframeTrack(\.stripX) {
            LinearKeyframe(1.2, duration: 0.32)
        }
        KeyframeTrack(\.stripY) {
            CubicKeyframe(-0.25, duration: 0.16, startVelocity: -3.125, endVelocity: 0)
            CubicKeyframe(-0.12, duration: 0.16, startVelocity: 0, endVelocity: 1.625)
        }
        KeyframeTrack(\.stripAngle) {
            LinearKeyframe(-20, duration: 0.32)
        }
        KeyframeTrack(\.stripOpacity) {
            LinearKeyframe(1, duration: 0.24)
            LinearKeyframe(0, duration: 0.08)
        }
        KeyframeTrack(\.sheetKick) {
            CubicKeyframe(6, duration: 0.05, startVelocity: 0, endVelocity: 0)
            CubicKeyframe(-16, duration: 0.12, startVelocity: 0, endVelocity: 0)
            CubicKeyframe(0, duration: 0.43, startVelocity: 0, endVelocity: 0)
        }
        KeyframeTrack(\.sheetFall) {
            LinearKeyframe(0, duration: 0.17)
            CubicKeyframe(1, duration: 0.43, startVelocity: 0, endVelocity: 2 / 0.43)
        }
        KeyframeTrack(\.sheetAngle) {
            LinearKeyframe(0, duration: 0.17)
            CubicKeyframe(-3, duration: 0.43, startVelocity: 0, endVelocity: 0)
        }
        KeyframeTrack(\.messageY) {
            LinearKeyframe(32, duration: 0.12)
            CubicKeyframe(0, duration: 0.38, startVelocity: -64 / 0.38, endVelocity: 0)
        }
        KeyframeTrack(\.messageOpacity) {
            LinearKeyframe(0, duration: 0.12)
            CubicKeyframe(1, duration: 0.22, startVelocity: 2 / 0.22, endVelocity: 0)
        }
    }

    static var duration: TimeInterval { timeline.duration }

    static func pose(at progress: CGFloat) -> Pose {
        timeline.value(time: Double(min(1, max(0, progress))) * duration)
    }
}

private struct PaperPieceRelease: AnimatableModifier {
    var progress: CGFloat
    let part: PaperPart
    let width: CGFloat
    let dropDistance: CGFloat
    var throwScale: CGFloat = 1

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = PaperReleaseMotion.pose(at: progress)
        let isStrip = part == .strip
        content
            .rotationEffect(.degrees(isStrip ? pose.stripAngle * Double(throwScale) : pose.sheetAngle),
                            anchor: isStrip ? .top : .center)
            .offset(x: isStrip ? pose.stripX * width * throwScale : 0,
                    y: isStrip ? pose.stripY * width * throwScale
                        : pose.sheetKick * width / 320 + pose.sheetFall * dropDistance)
            .opacity(isStrip ? pose.stripOpacity : 1)
    }
}

struct PaperMessageEntrance: AnimatableModifier {
    var progress: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = PaperReleaseMotion.pose(at: progress)
        content
            .offset(y: reduceMotion ? 0 : pose.messageY)
            .opacity(reduceMotion ? Double(progress) : pose.messageOpacity)
    }
}

/// Prepared once per cover size, rather than generating paper detail during a drag.
private struct PaperTearArtwork {
    static let ink = Color(red: 0.30, green: 0.28, blue: 0.25)
    static let fiberColor = Color.white.opacity(0.7)
    private static let sampleSpacing: CGFloat = 0.75

    let size: CGSize
    let seamY: CGFloat
    /// A small V notch cut into the left edge at the seam shows where the tear starts.
    let notchDepth: CGFloat
    let notchHalfHeight: CGFloat
    private let edge: [PaperEdgeSample]
    private let fringe: [PaperFiber]

    var textureRect: CGRect {
        CGRect(origin: .zero, size: size)
    }

    var headroom: CGFloat { ceil(size.width * (1 - cos(PaperCurl.maximumAngle)) / PaperCurl.maximumAngle + 96) }

    init(size: CGSize) {
        self.size = size
        seamY = min(80, max(64, size.height * 0.23)) - 14
        let seam = seamY
        let unit = size.width / 320
        notchDepth = 9 * unit
        notchHalfHeight = 6 * unit
        let xs = Array(stride(from: CGFloat(0), to: size.width, by: Self.sampleSpacing)) + [size.width]
        edge = xs.map { x in
            PaperEdgeSample(x: x, tear: seam + Self.roughness(at: x))
        }
        fringe = (0...Int(size.width / 6.2)).compactMap { index in
            guard StableRandom.unit(index, salt: 101) > 0.85 else { return nil }
            let x = (CGFloat(index) + StableRandom.unit(index, salt: 113)) * 6.2
            guard x < size.width else { return nil }
            let length = 0.8 + StableRandom.unit(index, salt: 127) * 1.7
            let slant = (StableRandom.unit(index, salt: 139) - 0.5) * 1.8
            return PaperFiber(root: CGPoint(x: x, y: seam + Self.roughness(at: x)), length: length, slant: slant)
        }
    }

    private var notchTip: CGPoint { CGPoint(x: notchDepth, y: sample(at: notchDepth).tear) }

    /// The envelope below the tear, with the notch's lower half (or the whole V before the
    /// tear passes it) cut from the left edge.
    func remainingSheet(through front: CGFloat) -> Path {
        var path = Path()
        guard front > notchDepth else {
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: seamY - notchHalfHeight))
            path.addLine(to: notchTip)
            path.addLine(to: CGPoint(x: 0, y: seamY + notchHalfHeight))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.closeSubpath()
            return path
        }
        path.move(to: notchTip)
        for sample in edge where sample.x > notchDepth {
            guard sample.x < front else { break }
            path.addLine(to: CGPoint(x: sample.x, y: sample.tear))
        }
        path.addLine(to: CGPoint(x: front, y: sample(at: front).tear))
        path.addLine(to: CGPoint(x: front, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: seamY + notchHalfHeight))
        path.closeSubpath()
        return path
    }

    /// The lifted strip, which keeps the notch's upper half.
    func strip(through front: CGFloat, curl: PaperCurl) -> Path {
        var path = Path()
        path.move(to: curl.point(.zero))
        for sample in edge {
            guard sample.x < front else { break }
            path.addLine(to: curl.point(CGPoint(x: sample.x, y: 0)))
        }
        path.addLine(to: curl.point(CGPoint(x: front, y: 0)))
        if front > notchDepth {
            path.addLine(to: curl.point(CGPoint(x: front, y: sample(at: front).tear)))
            for sample in edge.reversed() where sample.x < front && sample.x > notchDepth {
                path.addLine(to: curl.point(CGPoint(x: sample.x, y: sample.tear)))
            }
            path.addLine(to: curl.point(notchTip))
        } else {
            let y = seamY - notchHalfHeight * (1 - front / notchDepth)
            path.addLine(to: curl.point(CGPoint(x: front, y: y)))
        }
        path.addLine(to: curl.point(CGPoint(x: 0, y: seamY - notchHalfHeight)))
        path.closeSubpath()
        return path
    }

    /// The torn zigzag from the notch tip to the tear front.
    func tornEdge(through front: CGFloat, curl: PaperCurl? = nil) -> Path {
        var path = Path()
        guard front > notchDepth else { return path }
        path.move(to: curl?.point(notchTip) ?? notchTip)
        for sample in edge where sample.x > notchDepth && sample.x < front {
            let point = CGPoint(x: sample.x, y: sample.tear)
            path.addLine(to: curl?.point(point) ?? point)
        }
        let tip = CGPoint(x: front, y: sample(at: front).tear)
        path.addLine(to: curl?.point(tip) ?? tip)
        return path
    }

    /// The two cut faces of the notch.
    var notchOutline: Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: seamY - notchHalfHeight))
            path.addLine(to: notchTip)
            path.addLine(to: CGPoint(x: 0, y: seamY + notchHalfHeight))
        }
    }

    func fibers(through front: CGFloat, curl: PaperCurl? = nil) -> Path {
        var path = Path()
        let direction: CGFloat = curl == nil ? -1 : 1
        for fiber in fringe where fiber.root.x > notchDepth {
            guard fiber.root.x < front - 0.6 else { break }
            let root = CGPoint(x: fiber.root.x, y: fiber.root.y - direction * 0.3)
            let tip = CGPoint(x: root.x + fiber.slant, y: root.y + direction * fiber.length)
            path.move(to: curl?.point(root) ?? root)
            path.addLine(to: curl?.point(tip) ?? tip)
        }
        return path
    }

    /// The pre-cut zigzag the flap ends on; tearing follows it exactly.
    func guide(from start: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: start, y: sample(at: start).tear))
        for sample in edge where sample.x > start {
            path.addLine(to: CGPoint(x: sample.x, y: sample.tear))
        }
        return path
    }

    func flap(from start: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: start, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: 0))
        for sample in edge.reversed() where sample.x > start {
            path.addLine(to: CGPoint(x: sample.x, y: sample.tear))
        }
        path.addLine(to: CGPoint(x: start, y: sample(at: start).tear))
        path.closeSubpath()
        return path
    }

    private func sample(at x: CGFloat) -> PaperEdgeSample {
        let index = min(edge.count - 2, max(0, Int(x / Self.sampleSpacing)))
        let a = edge[index], b = edge[index + 1]
        let fraction = min(1, max(0, (x - a.x) / max(0.001, b.x - a.x)))
        return PaperEdgeSample(x: x, tear: a.tear + (b.tear - a.tear) * fraction)
    }

    /// A perforated zigzag: 7 pt teeth about 5 pt deep, each slightly irregular.
    private static func roughness(at x: CGFloat) -> CGFloat {
        let period: CGFloat = 7
        let cell = Int(floor(x / period))
        let local = x / period - CGFloat(cell)
        let apex = 0.5 + (StableRandom.unit(cell, salt: 61) - 0.5) * 0.23
        let rise = local < apex ? local / apex : (1 - local) / (1 - apex)
        let depth = 5 + (StableRandom.unit(cell, salt: 73) - 0.5) * 2
        let fine = noise(at: x, spacing: 0.85, salt: 47, smooth: false) * 0.3
        return -2.5 + rise * depth + fine
    }

    private static func noise(at x: CGFloat, spacing: CGFloat, salt: UInt64, smooth: Bool) -> CGFloat {
        let position = x / spacing
        let index = Int(floor(position))
        let fraction = position - CGFloat(index)
        let blend = smooth ? fraction * fraction * (3 - 2 * fraction) : fraction
        return (StableRandom.unit(index, salt: salt) * (1 - blend) + StableRandom.unit(index + 1, salt: salt) * blend) * 2 - 1
    }

}

private struct PaperCurl {
    static let maximumAngle: CGFloat = 0.72
    let front: CGFloat
    private let radius: CGFloat

    init(front: CGFloat, progress: CGFloat) {
        self.front = front
        let angle = Self.maximumAngle * sin(min(1, max(0, progress)) * .pi / 2)
        radius = front / max(0.0001, angle)
    }

    func point(_ point: CGPoint) -> CGPoint {
        guard front > 0.001, point.x < front else { return point }
        let angle = (front - point.x) / radius
        return CGPoint(x: front - radius * sin(angle), y: point.y - radius * (1 - cos(angle)))
    }

    func transform(at x: CGFloat) -> CGAffineTransform {
        let angle = (front - x) / radius
        let mapped = point(CGPoint(x: x, y: 0))
        return CGAffineTransform(a: cos(angle), b: sin(angle), c: 0, d: 1,
                                 tx: mapped.x - cos(angle) * x, ty: mapped.y - sin(angle) * x)
    }
}

private struct PaperEdgeSample {
    let x: CGFloat
    let tear: CGFloat
}

private struct PaperFiber {
    let root: CGPoint
    let length: CGFloat
    let slant: CGFloat
}

enum PaperMaterial {
    static let image = makeImage(isWhite: false)
    static let whiteImage = makeImage(isWhite: true)

    /// Both textures take ~100 ms each; build them in parallel off the main thread at launch
    /// so the first frame only waits for whichever finishes last.
    static func prewarm() {
        DispatchQueue.global(qos: .userInteractive).async { _ = image }
        DispatchQueue.global(qos: .userInteractive).async { _ = whiteImage }
    }

    private static func makeImage(isWhite: Bool) -> Image {
        let size = CGSize(width: 768, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let paper = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let base = isWhite
                ? UIColor(red: 0.982, green: 0.974, blue: 0.951, alpha: 1)
                : UIColor(red: 0.94, green: 0.915, blue: 0.86, alpha: 1)
            context.setFillColor(base.cgColor)
            context.fill(CGRect(origin: .zero, size: size))

            // Broad, translucent pools break up the color without a repeating tile.
            for index in 0..<240 {
                let light = index.isMultiple(of: 2)
                let color = isWhite
                    ? (light ? UIColor(white: 1, alpha: 0.045) : UIColor(white: 0.55, alpha: 0.018))
                    : light
                    ? UIColor(red: 1, green: 0.99, blue: 0.95, alpha: 0.06)
                    : UIColor(red: 0.55, green: 0.50, blue: 0.42, alpha: 0.03)
                let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                             locations: [0, 1]) {
                    let center = CGPoint(x: StableRandom.unit(index, salt: 11) * size.width,
                                         y: StableRandom.unit(index, salt: 23) * size.height)
                    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                               endCenter: center, endRadius: 20 + StableRandom.unit(index, salt: 37) * 95,
                                               options: [])
                }
            }

            context.setLineCap(.round)
            for batch in 0..<12 {
                let fibers = CGMutablePath()
                for index in 0..<4200 {
                    let seed = batch * 4200 + index
                    let x = StableRandom.unit(seed, salt: 43) * size.width
                    let y = StableRandom.unit(seed, salt: 59) * size.height
                    let length = 1.5 + pow(StableRandom.unit(seed, salt: 71), 2) * 24
                    let drift = (StableRandom.unit(seed, salt: 83) - 0.5) * 2.2
                    fibers.move(to: CGPoint(x: x, y: y))
                    fibers.addQuadCurve(to: CGPoint(x: x + length, y: y + drift),
                                        control: CGPoint(x: x + length * 0.45, y: y - drift * 0.6))
                }
                let light = batch.isMultiple(of: 2)
                context.setStrokeColor((isWhite
                    ? (light ? UIColor(white: 1, alpha: 0.24) : UIColor(white: 0.43, alpha: 0.065))
                    : light
                    ? UIColor(red: 1, green: 0.99, blue: 0.95, alpha: 0.10)
                    : UIColor(red: 0.50, green: 0.46, blue: 0.40, alpha: 0.05)).cgColor)
                context.setLineWidth(0.3 + CGFloat(batch % 3) * 0.25)
                context.addPath(fibers)
                context.strokePath()
            }

            for batch in 0..<6 {
                let flecks = CGMutablePath()
                for index in 0..<9000 {
                    let seed = batch * 9000 + index
                    let x = StableRandom.unit(seed, salt: 101) * size.width
                    let y = StableRandom.unit(seed, salt: 113) * size.height
                    let radius = 0.15 + pow(StableRandom.unit(seed, salt: 127), 4) * 0.8
                    flecks.addEllipse(in: CGRect(x: x, y: y, width: radius * 1.8, height: radius))
                }
                context.setFillColor((isWhite
                    ? (batch.isMultiple(of: 2) ? UIColor(white: 1, alpha: 0.24) : UIColor(white: 0.40, alpha: 0.13))
                    : batch.isMultiple(of: 2)
                    ? UIColor(red: 1, green: 0.99, blue: 0.96, alpha: 0.20)
                    : UIColor(red: 0.42, green: 0.38, blue: 0.32, alpha: 0.10)).cgColor)
                context.addPath(flecks)
                context.fillPath()
            }
        }
        return Image(uiImage: paper)
    }

}

struct ConfidentialStamp {
    /// Size-independent; built once and shared by every envelope.
    static let shared = ConfidentialStamp()
    static let width: CGFloat = 300
    static let height: CGFloat = 86

    let outline: Path
    let wear: Path

    init() {
        let font = CTFontCreateWithName("Georgia-Bold" as CFString, 72, nil)
        let characters = Array("CONFIDENTIAL".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, glyphs.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)

        var letters = Path()
        var cuts = Path()
        var cursor: CGFloat = 0
        for (index, glyph) in glyphs.enumerated() {
            if let shape = CTFontCreatePathForGlyph(font, glyph, nil) {
                letters.addPath(Path(shape), transform: CGAffineTransform(translationX: cursor, y: 0))
                let bounds = shape.boundingBoxOfPath
                if characters[index] == 73 {
                    cuts.addRect(CGRect(x: cursor + bounds.minX, y: bounds.midY,
                                        width: bounds.width, height: 0.9))
                } else {
                    cuts.addRect(CGRect(x: cursor + bounds.midX - 0.65, y: bounds.minY - 1,
                                        width: 1.3, height: bounds.height + 2))
                }
            }
            cursor += advances[index].width + 3
        }

        let bounds = letters.boundingRect
        let scaleX = (Self.width - 30) / bounds.width
        let scaleY = (Self.height - 29) / bounds.height
        let placement = CGAffineTransform(a: scaleX, b: 0, c: 0, d: -scaleY,
                                          tx: 15 - bounds.minX * scaleX, ty: 14 + bounds.maxY * scaleY)
        var outline = Path(roundedRect: CGRect(x: 3, y: 3, width: Self.width - 6, height: Self.height - 6),
                           cornerRadius: 7).strokedPath(StrokeStyle(lineWidth: 5.5))
        outline.addPath(letters, transform: placement)
        self.outline = outline

        var wear = cuts.applying(placement)
        for index in 0..<1700 {
            let x = StableRandom.unit(index, salt: 13) * Self.width
            let y = StableRandom.unit(index, salt: 29) * Self.height
            let radius = 0.15 + pow(StableRandom.unit(index, salt: 47), 3) * 1.05
            wear.addEllipse(in: CGRect(x: x, y: y, width: radius * 2.2, height: radius))
        }
        self.wear = wear
    }

}

/// Deterministic per-index noise (SplitMix64), so paper detail is identical on every launch.
enum StableRandom {
    static func unit(_ index: Int, salt: UInt64) -> CGFloat {
        var value = UInt64(bitPattern: Int64(index)) &+ salt &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return CGFloat(value >> 11) / CGFloat(UInt64.max >> 11)
    }
}
