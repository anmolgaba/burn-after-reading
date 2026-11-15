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
// flicker: the animation progress. seconds: time since ignition, so the fire flickers at the
// same speed whatever the effect duration.
[[ stitchable ]] half4 burn(float2 position, SwiftUI::Layer layer, float2 size, float frontY, float flicker, float seconds) {
    // Must match CardBurn.bulge in CardFadeEffect.swift.
    float bulge = 22.0 * sin(clamp(position.x / size.x, 0.0, 1.0) * M_PI_F);
    // Noise is keyed on position only, so bites stay pinned to the paper.
    float rag = (burnNoise(position * 0.035) - 0.5) * 34.0
              + (burnNoise(position * 0.11) - 0.5) * 12.0
              + (burnNoise(position * 0.45) - 0.5) * 3.0;
    float d = position.y - (frontY - bulge + rag);   // > 0 is burnt

    float heat = smoothstep(-36.0, -6.0, d) * (1.0 - smoothstep(-6.0, 0.0, d));
    float2 shimmer = float2(sin(position.y * 0.35 + seconds * 10.0), 0.0) * heat * 1.5;
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

    // The embers die with the particles once the front has left the card.
    float dying = 1.0 - smoothstep(0.8, 0.92, flicker);
    float flick = (0.65 + 0.35 * burnNoise(float2(position.x * 0.25, seconds * 7.5))) * dying;
    float rim = smoothstep(-3.0, -0.5, d) * (1.0 - smoothstep(0.5, 3.0, d)) * flick;
    float core = smoothstep(-1.0, 0.3, d) * (1.0 - smoothstep(0.3, 1.5, d));
    float halo = step(0.0, d) * exp(-max(d, 0.0) / 4.0) * 0.35 * flick;

    float3 ember = mix(purple, lilac, core) * rim + purple * halo;
    float emberAlpha = clamp(rim * 0.7 + halo, 0.0, 1.0);

    color.rgb += ember;
    color.a = clamp(color.a + emberAlpha * (1.0 - color.a), 0.0, 1.0);
    return half4(color);
}
