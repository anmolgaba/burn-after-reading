# Implementation plan: believable card burn + ash

Self-contained brief. Execute the steps in order. Project: iOS 17+, SwiftUI, no dependencies, Xcode project with hand-numbered IDs.

## Hard constraints

- **Do NOT modify `Stardust/Effects/ParticleCanvasView.swift`** (the purple particle effect). Its call site arguments (`particleCount: 200, movementDuration: activeSettings.fadeDuration`) also stay as they are. Only its `.offset` in `ContentView.swift` changes.
- Keep `withAnimation(.linear(duration: activeSettings.fadeDuration))` in `ContentView.swift` linear. All easing lives in `CardBurn.frontY`, so `progress == elapsed / duration` and the time-driven ash stays in sync with the progress-driven card.
- Reduce Motion keeps the plain opacity fade for the card.
- Don't add comments that narrate the change; match the existing comment style (short "why" notes).

## Why (what is wrong today)

1. The erase line travels the full card height (`CardFadeEffect.swift`), but the particle swirl's base only rises to the card's midpoint (`ContentView.swift`, the `.offset(y: particleStartOffset - cardFadeProgress * ...)` line). The fire and the erase are in different places.
2. The edge is a blurred alpha wipe: no scorch, char, glow, or purple. Nothing ties it to the particles.
3. The edge is a clean sine wave that slides sideways. Fire eats paper irregularly and the eaten shape stays put.
4. Particles fade out during the last second while the top quarter of the card is still erasing.
5. No ash.

## Target behaviour

- One shared "burn front" drives the card, the particle placement, and the ash.
- The front ignites slowly, climbs steadily, is higher in the centre than at the corners, and reaches the top at **progress 0.8**. The last 20% is the fire dying, which coincides with the particles' existing 1 s fade-out.
- Card edge, from unburnt to burnt: sepia heat scorch with a violet light cast → grainy black char → flickering lilac/purple ember rim → transparent with a faint purple halo. Ragged, pinned to the paper.
- Particles appear to lift out of the ember rim for the whole burn.
- Ash flakes shed from the rim, flutter down, and build a small lumpy heap along the **bottom edge of the screen** (behind the Reset button). The heap stays until Reset.

---

## Step 1 — Create `Stardust/Effects/Burn.metal`

```metal
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float burnHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float burnNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = burnHash(i);
    float b = burnHash(i + float2(1.0, 0.0));
    float c = burnHash(i + float2(0.0, 1.0));
    float d = burnHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// frontY: burn line in layer points (y grows downward; everything below it is burnt).
// flicker: any value that changes every frame (the animation progress).
[[ stitchable ]] half4 burn(float2 position, SwiftUI::Layer layer, float2 size, float frontY, float flicker) {
    // Must match CardBurn.bulge in CardFadeEffect.swift.
    float bulge = 22.0 * sin(clamp(position.x / size.x, 0.0, 1.0) * M_PI_F);
    // Noise is keyed on position only, so bites stay pinned to the paper.
    float rag = (burnNoise(position * 0.035) - 0.5) * 34.0
              + (burnNoise(position * 0.11) - 0.5) * 12.0
              + (burnNoise(position * 0.45) - 0.5) * 3.0;
    float d = position.y - (frontY - bulge + rag);   // > 0 is burnt

    float heat = smoothstep(-36.0, -6.0, d) * (1.0 - smoothstep(-6.0, 0.0, d));
    float2 shimmer = float2(sin(position.y * 0.35 + flicker * 40.0), 0.0) * heat * 1.5;
    float4 color = float4(layer.sample(position + shimmer));

    float3 purple = float3(0.69, 0.32, 0.87);
    float3 lilac = float3(0.97, 0.90, 1.0);

    float scorch = smoothstep(-28.0, -8.0, d);
    color.rgb *= mix(float3(1.0), float3(0.62, 0.44, 0.28), scorch);

    float cast = exp(min(d, 0.0) / 14.0);
    color.rgb += purple * 0.22 * cast * color.a;

    float grain = burnNoise(position * 1.7);
    float charred = smoothstep(-9.0, -2.0, d) * (0.85 + 0.15 * grain);
    color.rgb = mix(color.rgb, float3(0.05, 0.04, 0.05) * color.a, charred);

    float paper = 1.0 - smoothstep(0.0, 2.0, d);
    color *= paper;

    float flick = 0.65 + 0.35 * burnNoise(float2(position.x * 0.25, flicker * 30.0));
    float rim = smoothstep(-3.0, -0.5, d) * (1.0 - smoothstep(0.5, 3.0, d)) * flick;
    float core = smoothstep(-1.0, 0.3, d) * (1.0 - smoothstep(0.3, 1.5, d));
    float halo = step(0.0, d) * exp(-max(d, 0.0) / 4.0) * 0.35 * flick;

    float3 ember = mix(purple, lilac, core) * rim + purple * halo;
    float emberAlpha = clamp(rim * 0.7 + halo, 0.0, 1.0);

    color.rgb += ember;
    color.a = clamp(color.a + emberAlpha * (1.0 - color.a), 0.0, 1.0);
    return half4(color);
}
```

Notes: `layer.sample` returns premultiplied colour, which is why tints are scaled by `color.a`. If the Metal compiler complains about half/float mixing, keep everything `float` and cast only at `layer.sample` and the `return`.

## Step 2 — Rewrite `Stardust/Effects/CardFadeEffect.swift`

Replace the whole file with:

```swift
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
    private static let ignition: CGFloat = 1.35

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
        let front = CardBurn.frontY(progress: progress, height: cardHeight) - 10
        let line = min(max(front, 0), cardHeight - 4)
        content.offset(y: line - cardHeight * 0.91)
    }
}
```

## Step 3 — Create `Stardust/Effects/AshFallView.swift`

A stateless, closed-form particle layer like `ParticleCanvasView` (positions are pure functions of elapsed time and a per-flake seed). Reuse `StableRandom.unit(_:salt:)` from `PaperTearRevealCover.swift` (already internal, returns 0...1).

```swift
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
}
```

Implement `draw(in:size:elapsed:)` to this spec (all random values `r(n)` are `StableRandom.unit(index, salt: n)` with distinct salts):

**Per flake `index` in `0..<flakeCount`:**

| Quantity | Formula |
|---|---|
| `x0` | `cardFrame.minX + r1 * cardFrame.width` |
| `yLocal` | `cardFrame.height * (1 - pow(r2, 1.6))` (biased toward the bottom of the card) |
| `birth` | `CardBurn.progress(reaching: CGPoint(x: x0 - cardFrame.minX, y: yLocal), in: cardFrame.size) * duration` |
| `age` | `elapsed - birth`; skip the flake if `< 0` |
| `fallDuration` | `0.9 + 0.9 * r3` seconds (independent of height, so the last flakes land ~1.2 s after the card is gone) |
| `landX` | `x0 + (cardFrame.midX - x0) * 0.25 + (r4 - 0.5) * 40` |
| `landY` | `size.height - pileHeight(landX) * r5 - 1` |
| `k` | `min(1, age / fallDuration)` |
| `y` | lerp(`cardFrame.minY + yLocal`, `landY`, `pow(k, 1.6)`) |
| `x` | lerp(`x0`, `landX`, `k`) + `sin(age * (1.5 + 1.5 * r6) * 2π + r7 * 2π) * (6 + 8 * r8) * (1 - k)` |
| size | width `1.5 + 2.5 * r9`, height `0.6 ×` width |
| rotation | `r11 * π + min(age, fallDuration) * (1 + 3 * r10)` (freezes on landing) |
| colour | ember `Color(red: 0.78, green: 0.50, blue: 0.95)` cooling to warm grey `Color(red: g + 0.02, green: g, blue: g)` with `g = 0.16 + 0.16 * r12`, mix factor `min(1, age / 0.4)`; opacity 0.9 |
| pile embers | flakes where `index % 23 == 0`: after landing, re-tint toward the ember colour by `max(0, 1 - (age - fallDuration) / 1.5)` so a few wink purple in the heap and die |

Draw each flake as a small rotated rectangle path (translate + rotate a copy of the context, fill).

**Pile:**

- `pileHeight(x) = 14 * exp(-pow((x - cardFrame.midX) / (0.36 * cardFrame.width), 2)) * (0.75 + 0.5 * lump(x))`, where `lump(x)` is 1-D value noise: linear interpolation of `StableRandom.unit(Int(floor(x / 9)), salt: 71)` between neighbouring 9 pt cells.
- `landed` = fraction of flakes with `k >= 1` (compute in a first pass over the flakes).
- Path from `x = midX - 0.6 * width` to `midX + 0.6 * width` in 3 pt steps at `y = size.height - pileHeight(x) * pow(landed, 0.8)`, closed along `size.height`.
- Draw order: (1) the pile path on a copy of the context with `.blur(radius: 3)` and opacity 0.25 as a dust fringe; (2) the pile filled with a vertical linear gradient from `Color(white: 0.34)` at its top to `Color(white: 0.16)` at the floor; (3) all flakes on top (landed flakes give the heap texture).
- Skip pile drawing while `landed == 0`.

**Reduce Motion:** treat every flake as landed (`k = 1`, no ember tint) and `landed = 1`, and multiply the whole layer's opacity by `min(1, elapsed / 0.3)`. No falling.

## Step 4 — Edit `Stardust/ContentView.swift`

1. **Card frame instead of card top.** Replace `@State private var messageCardTop: CGFloat = 0` with `@State private var messageCardFrame: CGRect = .zero`. Rename `MessageCardTopPreferenceKey` to `MessageCardFramePreferenceKey` with `Value = CGRect`, `defaultValue = .zero`; publish `proxy.frame(in: .named("messageRevealStage"))` and store it in `messageCardFrame`. Replace the one read of `messageCardTop` (in `dropDistance`) with `messageCardFrame.minY`.

2. **Ash state.** Add `@State private var ashStart: Date?`.
   - In the `.task(id: phase)` `.disappearing` case, set `ashStart = Date()` immediately before the `withAnimation` call.
   - In `resetCard()`, add `ashStart = nil` inside the `withTransaction` block.

3. **Ash layer.** Immediately after `.coordinateSpace(name: "messageRevealStage")` and before `.background(Self.stageColor.ignoresSafeArea())`, add:

   ```swift
   .background {
       if let ashStart {
           AshFallView(cardFrame: messageCardFrame,
                       start: ashStart,
                       duration: activeSettings.reduceMotion ? 0.3 : activeSettings.fadeDuration,
                       reduceMotion: activeSettings.reduceMotion)
               .id(effectID)
               .ignoresSafeArea(edges: .bottom)
       }
   }
   ```

   This puts ash above the stage colour and behind the scroll view (so flakes pass behind the Reset button), with the same origin as the named coordinate space and its floor at the physical bottom of the screen.

4. **Card modifier.** Change the call to
   `.modifier(CardFadeEffect(progress: cardFadeProgress, size: CGSize(width: width, height: cardHeight), reduceMotion: activeSettings.reduceMotion))`.

5. **Particle anchoring.** On `ParticleCanvasView`, replace the `.offset(y: particleStartOffset - cardFadeProgress * (cardHeight * 0.5 + particleStartOffset))` line and its comment with:

   ```swift
   // The swirl lifts out of the burn line for the whole fade.
   .modifier(BurnTrackingOffset(progress: cardFadeProgress, cardHeight: cardHeight))
   ```

   Delete the now-unused `let particleStartOffset: CGFloat = 12`. Leave everything else on the overlay (`.id`, `.zIndex`, `.transition(.opacity)`, etc.) unchanged.

## Step 5 — Register the new files in `Stardust.xcodeproj/project.pbxproj`

First `grep` the file to confirm IDs `…023` to `…026` are unused. Then add, following the existing line format exactly:

- **PBXBuildFile section**
  - `000000000000000000000024 /* Burn.metal in Sources */ = {isa = PBXBuildFile; fileRef = 000000000000000000000023 /* Burn.metal */; };`
  - `000000000000000000000026 /* AshFallView.swift in Sources */ = {isa = PBXBuildFile; fileRef = 000000000000000000000025 /* AshFallView.swift */; };`
- **PBXFileReference section**
  - `000000000000000000000023 /* Burn.metal */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.metal; path = Burn.metal; sourceTree = "<group>"; };`
  - `000000000000000000000025 /* AshFallView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AshFallView.swift; sourceTree = "<group>"; };`
- **PBXGroup `00000000000000000000001A /* Effects */` children:** add both file refs.
- **PBXSourcesBuildPhase `000000000000000000000007` files:** add both build files (Metal goes in Sources, not Resources).

## Step 6 — Update `README.md`

Rewrite the sentences that describe the disappearance so they match: the "existing bottom-up fade … soft, rippling edge" sentence, and the paragraph beginning "`ContentView.swift` anchors the overlay with `.overlay(alignment: .bottom)` and a 12-point bottom inset". Mention: the shared burn front (`CardBurn`), the Metal burn shader, the swirl tracking the front, the ash layer and where it settles, that the pile clears on Reset, and the Reduce Motion behaviour (plain fade; static pile fades in). Keep the README's existing plain, descriptive style.

---

## Verification

1. Build: `xcodebuild -project Stardust.xcodeproj -scheme Stardust -destination 'generic/platform=iOS Simulator' build`. This is what proves the shader compiles; fix any Metal type errors.
2. Run in an iPhone simulator. In settings set **Effect duration** to 6 s for slow inspection. Tear the envelope, wait out the reading timer, then check at roughly 10 / 40 / 75 / 100% of the burn and ~3 s after:
   - Card is fully intact (no scorch) before the burn starts.
   - The bottom edge browns, then catches; centre burns ahead of the corners.
   - Scorch → char → purple ember rim bands are all visible; the ragged shape does not slide sideways.
   - Purple particles emerge from the rim throughout, not from empty space.
   - The card is completely gone by the time the particles finish fading.
   - Flakes fall from the rim, pass behind the Reset button, and a heap builds at the very bottom of the screen and stays.
3. Repeat at the default 3 s and the 1 s minimum.
4. Tap Reset after finishing, and navigate away/back mid-burn: card, particles and ash all clear at once.
5. Turn on Reduce Motion (Simulator → Settings → Accessibility → Motion): plain fade, pile fades in, no falling flakes.
6. Confirm `git diff`/file timestamp shows `ParticleCanvasView.swift` untouched.

## Tuning knobs (adjust by eye only if needed)

- Tail of the swirl rising too far above the card near the end → in `BurnTrackingOffset`, raise the lower clamp from `0` to about `cardHeight * 0.15`.
- Burn too jagged / too smooth → the `34.0` and `12.0` noise amplitudes in `Burn.metal` (if raised, raise `CardBurn.startMargin`/`endMargin` by the same amount).
- Ember rim too strong on the ivory paper → scale `ember` in `Burn.metal` (try `0.8`).
- Ash heap size → the `14` in `pileHeight` and `flakeCount`.
