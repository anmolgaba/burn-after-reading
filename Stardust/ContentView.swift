import SwiftUI
import CoreText

struct ContentView: View {
    private enum MessagePhase {
        case covered, opening, revealed, disappearing, finished
    }

    private struct EffectSettings {
        var messageDuration = 5.0
        var movementDuration = 4.0
        var reduceMotion = false

        var fadeDuration: Double { movementDuration }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var isMessageFocused: Bool
    @State private var isShowingSettings = false
    @State private var phase = MessagePhase.covered
    @State private var isViewActive = false
    @State private var areParticlesVisible = false
    @State private var cardFadeProgress: CGFloat = 0
    @State private var paperReleaseProgress: CGFloat = 0
    @State private var messageCardFrame: CGRect = .zero
    @State private var ashStart: Date?
    @State private var ashSweepStart: Date?
    /// 0 while a fresh envelope is above the stage, 1 once it has settled.
    @State private var coverSettle: CGFloat = 1
    @State private var effectID = UUID()
    @State private var activeSettings = EffectSettings()
    @State private var readingWindow: MessageReadingWindow?
    @AppStorage("messageDuration") private var messageDuration = 5.0
    @AppStorage("effectDuration") private var movementDuration = 4.0
    @ScaledMetric(relativeTo: .title) private var messageSize = 26

    private static let salutation = "Dear Rahul,"
    private static let message = "meet me at cubbon park around 5pm after school ends"
    private static let stageColor = Color(red: 0.925, green: 0.922, blue: 0.914)
    private static let lineSpacing: CGFloat = 6
    private static let inset: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(Color(white: 0.25))
                                .frame(width: 48, height: 48)
                                .background(SoftCapsule(shape: Circle()))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Effect settings")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer(minLength: 24)

                    messageCard(width: min(geometry.size.width - 88, 420), containerHeight: geometry.size.height)

                    Spacer(minLength: 24)

                    // Keeps the letter where it sat when a button lived here.
                    Color.clear
                        .frame(height: 52)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            // Only scroll when Dynamic Type makes the letter taller than the screen,
            // so a slightly diagonal tear never rubber-bands the page.
            .scrollBounceBehavior(.basedOnSize)
            // The rising fire leaves through the top of the screen, not the safe-area edge.
            .scrollClipDisabled()
        }
        .coordinateSpace(name: "messageRevealStage")
        .overlay {
            // No visible control: tapping the ash heap sweeps it away and deals a fresh envelope.
            Button(action: sweepAsh) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 120)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(phase == .finished)
            .disabled(phase != .finished)
            .accessibilityHidden(phase != .finished)
            .accessibilityLabel("Replay")
            .accessibilityIdentifier("resetMessageButton")
            .accessibilityHint("Sweeps the ash away and restores the covered message.")
        }
        .background {
            if let ashStart {
                AshFallView(cardFrame: messageCardFrame,
                            start: ashStart,
                            duration: activeSettings.reduceMotion ? 0.3 : activeSettings.fadeDuration,
                            reduceMotion: activeSettings.reduceMotion,
                            sweepStart: ashSweepStart)
                    .id(effectID)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(Self.stageColor.ignoresSafeArea())
        .tint(Color(white: 0.3))
        // The paper palette is light only; without this the status bar turns white in dark mode.
        .preferredColorScheme(.light)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: phase) { _, new in new == .disappearing }
        .onChange(of: phase) { _, new in
            if new == .revealed {
                isMessageFocused = true
            } else if new == .finished {
                AccessibilityNotification.Announcement("The message has burnt away.").post()
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            settings
        }
        .onAppear { isViewActive = true }
        .onDisappear {
            isViewActive = false
            resetCard()
        }
        .task(id: phase) {
            let runID = effectID
            switch phase {
            case .revealed:
                guard let readingWindow else { return }
                do {
                    try await ContinuousClock().sleep(until: readingWindow.deadline)
                    try Task.checkCancellation()
                    guard isCurrentRun(runID), phase == .revealed else { return }
                    areParticlesVisible = !activeSettings.reduceMotion
                    self.readingWindow = nil
                    phase = .disappearing
                } catch {
                    // Resetting or leaving the view cancels the reading delay.
                }
            case .disappearing:
                // The particles have rendered before the card begins to fade.
                let animation: Animation = activeSettings.reduceMotion
                    ? .easeOut(duration: 0.3)
                    : .linear(duration: activeSettings.fadeDuration)
                ashStart = Date()
                withAnimation(animation, completionCriteria: .removed) {
                    cardFadeProgress = 1
                } completion: {
                    guard isCurrentRun(runID), phase == .disappearing else { return }
                    withAnimation(.easeOut(duration: 0.25), completionCriteria: .removed) {
                        areParticlesVisible = false
                    } completion: {
                        guard isCurrentRun(runID), phase == .disappearing else { return }
                        phase = .finished
                    }
                }
            case .covered, .opening, .finished:
                break
            }
        }
    }

    private func messageCard(width: CGFloat, containerHeight: CGFloat) -> some View {
        let layout = LetterLayout.cached(width: width, fontSize: messageSize, inset: Self.inset,
                                         lineSpacing: Self.lineSpacing, text: Self.letterText)
        let cardHeight = max(width * 1.25, layout.textHeight + Self.inset + layout.cornerReserve)
        let runID = effectID
        let motionIsReduced = phase == .covered ? reduceMotion : activeSettings.reduceMotion
        let dropDistance = max(cardHeight, containerHeight - messageCardFrame.minY + width * 0.08 + 32)

        return ZStack {
            if phase == .disappearing || phase == .finished {
                BurntRemains(size: CGSize(width: width, height: cardHeight))
                    .opacity(ashSweepStart == nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: ashSweepStart)
            }

            Text(Self.letterText)
                .font(PaperTypography.font(size: messageSize))
                .lineSpacing(Self.lineSpacing)
                .multilineTextAlignment(.leading)
                .foregroundStyle(Color(white: 0.13))
                .frame(width: layout.textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Self.inset)
                .frame(width: width, height: cardHeight, alignment: .topLeading)
                .background {
                    MessagePaperSurface(layout: layout)
                }
                .overlay(alignment: .topLeading) {
                    let postmark = LetterPostmark(cardWidth: width, inset: Self.inset)
                    PostmarkClock(window: phase == .revealed ? readingWindow : nil,
                                  duration: phase == .covered ? messageDuration : activeSettings.messageDuration,
                                  isSpent: phase == .disappearing || phase == .finished,
                                  radius: postmark.radius,
                                  reduceMotion: motionIsReduced)
                        .rotationEffect(LetterPostmark.tilt)
                        .position(postmark.center)
                }
                .modifier(CardFadeEffect(progress: cardFadeProgress, size: CGSize(width: width, height: cardHeight),
                                         reduceMotion: activeSettings.reduceMotion,
                                         duration: activeSettings.fadeDuration))
                .shadow(color: .black.opacity(0.07), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(0.055), radius: 12, x: 0, y: 7)
                .overlay(alignment: .bottom) {
                    if areParticlesVisible {
                        ParticleCanvasView(particleCount: 200, movementDuration: activeSettings.fadeDuration)
                            .id(effectID)
                            // The swirl lifts out of the burn line for the whole fade.
                            .modifier(BurnTrackingOffset(progress: cardFadeProgress, cardHeight: cardHeight))
                            .zIndex(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
                .modifier(PaperMessageEntrance(progress: paperReleaseProgress, reduceMotion: motionIsReduced))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.salutation) \(Self.message)")
                .accessibilityIdentifier("messageCard")
                .accessibilityHidden(phase != .revealed)
                .accessibilityFocused($isMessageFocused)

            if phase == .covered || phase == .opening {
                revealCover(size: CGSize(width: width, height: cardHeight), dropDistance: dropDistance, runID: runID)
                    .id(runID)
                    .offset(y: (coverSettle - 1) * 24)
                    .opacity(Double(min(1, coverSettle)))
            }
        }
        .frame(width: width, height: cardHeight)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MessageCardFramePreferenceKey.self,
                                       value: proxy.frame(in: .named("messageRevealStage")))
            }
        }
        .onPreferenceChange(MessageCardFramePreferenceKey.self) { messageCardFrame = $0 }
    }

    private static var letterText: String { "\(salutation)\n\n\(message)" }

    private func revealCover(size: CGSize, dropDistance: CGFloat, runID: UUID) -> some View {
        PaperTearRevealCover(
            size: size,
            reduceMotion: phase == .covered ? reduceMotion : activeSettings.reduceMotion,
            messageDuration: phase == .covered ? messageDuration : activeSettings.messageDuration,
            releaseProgress: $paperReleaseProgress,
            dropDistance: dropDistance,
            onRevealStarted: { beginReveal(runID: runID) },
            onRevealCompleted: {
                guard isCurrentRun(runID), phase == .opening else { return }
                // VoiceOver needs time to reach the letter and read it aloud.
                readingWindow = MessageReadingWindow(
                    duration: activeSettings.messageDuration + (voiceOverEnabled ? 8 : 0))
                phase = .revealed
            }
        )
    }

    private func beginReveal(runID: UUID) {
        guard isCurrentRun(runID), phase == .covered else { return }
        activeSettings = EffectSettings(
            messageDuration: messageDuration,
            movementDuration: movementDuration,
            reduceMotion: reduceMotion
        )
        phase = .opening
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        isViewActive && effectID == runID
    }

    private func sweepAsh() {
        guard phase == .finished, ashSweepStart == nil else { return }
        let runID = effectID
        ashSweepStart = Date()
        Task {
            try? await Task.sleep(for: .seconds(AshFallView.sweepDuration))
            guard isCurrentRun(runID) else { return }
            resetCard()
        }
    }

    private func resetCard() {
        let settles = isViewActive && !reduceMotion
        // Invalidate animation callbacks as well as recreating the cover and particles.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            effectID = UUID()
            phase = .covered
            cardFadeProgress = 0
            paperReleaseProgress = 0
            readingWindow = nil
            areParticlesVisible = false
            ashStart = nil
            ashSweepStart = nil
            coverSettle = settles ? 0 : 1
        }
        guard settles else { return }
        // Next run loop pass, so the envelope is drawn above the stage before it drops.
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.45, bounce: 0.2)) {
                coverSettle = 1
            }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Message duration") {
                        Text("\(Int(messageDuration)) seconds")
                            .monospacedDigit()
                    }
                    Slider(value: $messageDuration, in: 3...8, step: 1) {
                        Text("Message duration")
                    }
                    .accessibilityValue("\(Int(messageDuration)) seconds")
                    .accessibilityHint("Time to read the message before it begins disappearing.")
                    LabeledContent("Effect duration") {
                        Text("\(movementDuration, specifier: "%.1f") seconds")
                            .monospacedDigit()
                    }
                    Slider(value: $movementDuration, in: 2...7, step: 0.5) {
                        Text("Effect duration")
                    }
                    .accessibilityValue("\(movementDuration, specifier: "%.1f") seconds")
                } header: {
                    Text("Stardust")
                } footer: {
                    Text("Changes apply the next time you reveal the message. Reduce Motion uses gentle fades.")
                }
            }
            .navigationTitle("Effect settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isShowingSettings = false }
                }
            }
        }
        // Sheets don't inherit the stage's tint, and the sliders ignore the asset accent here.
        .tint(Color(white: 0.3))
        .presentationDetents([.medium, .large])
    }
}

enum PaperTypography {
    /// Playwrite US Trad when bundled in `Fonts/`, otherwise a built-in connected script.
    nonisolated(unsafe) private(set) static var fontName = "SnellRoundhand"

    /// Playwrite ships as a variable font; pin the regular weight the reference uses.
    static func uiFont(size: CGFloat) -> UIFont {
        let base = CTFontCreateWithName(fontName as CFString, size, nil)
        let variation = CTFontDescriptorCreateWithAttributes([
            kCTFontVariationAttribute: [NSNumber(value: 0x77676874): NSNumber(value: 300)] // 'wght'
        ] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, variation) as UIFont
    }

    static func font(size: CGFloat) -> Font {
        // SwiftUI drops CTFont variations; its weight maps onto Playwrite's wght axis.
        .custom(fontName, fixedSize: size).weight(.light)
    }

    static func registerBundledFonts() {
        guard let folder = Bundle.main.url(forResource: "Fonts", withExtension: nil),
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        var candidates: [String] = []
        for url in urls where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            for descriptor in descriptors {
                if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                   name.localizedCaseInsensitiveContains("playwrite") {
                    candidates.append(name)
                }
            }
        }
        if let name = candidates.first(where: { $0.hasSuffix("-Regular") }) ?? candidates.first {
            fontName = name
        }
    }
}

private struct MessageReadingWindow {
    let start: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let duration: Double

    init(duration: Double) {
        let start = ContinuousClock().now
        self.start = start
        self.deadline = start.advanced(by: .seconds(duration))
        self.duration = duration
    }

    private func elapsed(reduceMotion: Bool) -> Double {
        let components = start.duration(to: ContinuousClock().now).components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return reduceMotion ? floor(seconds) : seconds
    }

    func progress(reduceMotion: Bool) -> CGFloat {
        CGFloat(min(1, max(0, elapsed(reduceMotion: reduceMotion) / duration)))
    }

    func secondsRemaining(reduceMotion: Bool) -> Int {
        max(0, Int((duration - elapsed(reduceMotion: reduceMotion)).rounded(.up)))
    }
}

/// The letter's postmark doubles as the reading timer: its ring is inked away clockwise from
/// twelve o'clock, and the date is re-stamped with the whole seconds left.
private struct PostmarkClock: View {
    let window: MessageReadingWindow?
    let duration: Double
    let isSpent: Bool
    let radius: CGFloat
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil, paused: window == nil)) { _ in
            let progress = window?.progress(reduceMotion: reduceMotion) ?? (isSpent ? 1 : 0)
            let seconds = window?.secondsRemaining(reduceMotion: reduceMotion) ?? (isSpent ? 0 : Int(duration.rounded(.up)))
            let circumference = 2 * .pi * radius
            ZStack {
                Circle()
                    .trim(from: progress, to: 1)
                    // Uneven dashes read as ink skipping on a rubber stamp; the phase pins them
                    // to the paper so they don't crawl as the ring shortens.
                    .stroke(PostalMarks.blue.opacity(0.82),
                            style: StrokeStyle(lineWidth: max(0.8, radius / 11),
                                               dash: [radius * 0.55, radius * 0.05, radius * 0.32, radius * 0.07],
                                               dashPhase: progress * circumference))
                    .rotationEffect(.degrees(-90))
                Text("\(seconds)")
                    .font(.system(size: radius * 0.66, weight: .bold, design: .serif))
                    .foregroundStyle(PostalMarks.red.opacity(0.85))
                    .id(seconds)
                    // Each new second lands like a stamp: slightly large, then pressed flat.
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 1.35).combined(with: .opacity),
                        removal: .opacity))
            }
            .frame(width: radius * 2, height: radius * 2)
            .animation(.easeOut(duration: 0.18), value: seconds)
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The postmark clock sits top right, where a postmark lands on real mail and where the eye
/// starts reading, clear of the salutation.
private struct LetterPostmark {
    static let tilt = Angle.degrees(-8)
    let center: CGPoint
    let radius: CGFloat

    init(cardWidth: CGFloat, inset: CGFloat) {
        radius = cardWidth * 0.075
        center = CGPoint(x: cardWidth - inset * 0.8 - radius, y: inset * 0.8 + radius)
    }
}

/// Measures the handwritten body so ruled lines sit under each written line.
private struct LetterLayout {
    let inset: CGFloat
    let textWidth: CGFloat
    let textHeight: CGFloat
    let firstBaseline: CGFloat
    let lineAdvance: CGFloat
    let lineCount: Int
    let cornerReserve: CGFloat

    private static var cache: (key: String, layout: LetterLayout)?

    /// Text measurement takes several milliseconds, and ContentView's body re-runs on every phase
    /// change (including the frame the message lands), so measure once per size.
    static func cached(width: CGFloat, fontSize: CGFloat, inset: CGFloat, lineSpacing: CGFloat,
                       text: String) -> LetterLayout {
        let key = "\(width)|\(fontSize)|\(inset)|\(lineSpacing)|\(PaperTypography.fontName)|\(text)"
        if let cache, cache.key == key { return cache.layout }
        let layout = LetterLayout(width: width, fontSize: fontSize, inset: inset, lineSpacing: lineSpacing, text: text)
        cache = (key, layout)
        return layout
    }

    private init(width: CGFloat, fontSize: CGFloat, inset: CGFloat, lineSpacing: CGFloat, text: String) {
        self.inset = inset
        textWidth = width - inset * 2
        let font = PaperTypography.uiFont(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        lineAdvance = font.lineHeight + lineSpacing
        firstBaseline = inset + font.ascender
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        lineCount = max(1, lines)
        textHeight = ceil(manager.usedRect(for: container).height)
        cornerReserve = inset
    }
}

private struct MessagePaperSurface: View {
    let layout: LetterLayout

    var body: some View {
        PaperMaterial.whiteImage
            .resizable()
            .interpolation(.high)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.20), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.025), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .overlay {
                Canvas { context, size in
                    let rule = Color.black.opacity(0.075)
                    let left = layout.inset
                    let right = size.width - layout.inset * 0.75
                    // Ruled writing lines just below each baseline, then a short one after the text.
                    for index in 0...layout.lineCount {
                        let y = layout.firstBaseline + CGFloat(index) * layout.lineAdvance + 4
                        guard y < size.height - layout.cornerReserve * 0.4 else { break }
                        let end = index == layout.lineCount ? left + (right - left) * 0.55 : right
                        context.stroke(Path { $0.move(to: CGPoint(x: left, y: y)); $0.addLine(to: CGPoint(x: end, y: y)) },
                                       with: .color(rule), lineWidth: 0.6)
                    }

                    let postmark = LetterPostmark(cardWidth: size.width, inset: layout.inset)
                    var face = context
                    face.translateBy(x: postmark.center.x, y: postmark.center.y)
                    face.rotate(by: LetterPostmark.tilt)
                    PostalMarks.drawPostmark(in: face, center: .zero, radius: postmark.radius, clockFace: true)

                    context.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25)),
                                   with: .color(.black.opacity(0.06)), lineWidth: 0.5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// What the fire leaves on the stage: a soot shadow the size of the letter and one scorched line.
/// It sits behind the letter, so the burn front uncovers it.
private struct BurntRemains: View {
    let size: CGSize

    private static let scorch = Color(red: 0.36, green: 0.27, blue: 0.20)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Self.scorch.opacity(0.22))
                .padding(22)
                .blur(radius: 20)

            Text("burnt after reading")
                .font(PaperTypography.font(size: 24))
                .foregroundStyle(Self.scorch.opacity(0.6))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burnt after reading")
    }
}

/// The reference's soft, slightly raised pale controls.
private struct SoftCapsule<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(LinearGradient(colors: [Color(white: 0.965), Color(white: 0.93)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.stroke(.white.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
            .shadow(color: .black.opacity(0.06), radius: 0.5, x: 0, y: 0.5)
    }
}

private struct MessageCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    /// Views without a frame report the empty default; don't let them erase the card's.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

#Preview {
    ContentView()
}
