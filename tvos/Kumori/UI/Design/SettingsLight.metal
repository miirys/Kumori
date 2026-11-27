#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Settings' background: threads and veils of white silk flowing slowly on black, lit by four
// soft lights that wander the whole screen on paths taken from noise, so nothing runs on a
// loop or settles in the middle. Only shades of white.

static float kl_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float kl_noise(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = kl_hash(i);
    float b = kl_hash(i + float2(1.0, 0.0));
    float c = kl_hash(i + float2(0.0, 1.0));
    float d = kl_hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float kl_fbm(float2 p) {
    float s = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        s += a * kl_noise(p);
        p = float2(1.6 * p.x - 1.2 * p.y + 3.1, 1.2 * p.x + 1.6 * p.y + 1.7);
        a *= 0.5;
    }
    return s;
}

static float kl_ease(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Where each light is comes from the app (TVGlowBackdrop.lightPath), worked out once per
// frame instead of once for every pixel: the four paths were more than half the shader's work.

/// `size` is the view's size in points, `time` seconds, and `lightsA` and `lightsB` the
/// centres of the four lights (0 and 1 in A, 2 and 3 in B) as fractions of the size.
[[ stitchable ]] half4 kumoriSettingsLight(float2 position, half4 color, float2 size, float time, float4 lightsA, float4 lightsB) {
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2(uv.x * aspect, uv.y) * 0.9;
    float t = time;

    // The silk: noise bent through itself, flowing slowly, with soft bright threads where it
    // crosses its middle and broad veils where it is high.
    float2 q = float2(kl_fbm(p + float2(0.020 * t, -0.013 * t)),
                      kl_fbm(p + float2(5.2 - 0.017 * t, 1.3 + 0.011 * t)));
    float2 w = p + 1.8 * q;
    float f = kl_fbm(w + float2(0.03 * t, 0.0));
    float ridge = 1.0 - abs(2.0 * f - 1.0);
    float silk = pow(ridge, 6.0);
    float veil = kl_ease(0.35, 0.8, f);

    // Four lights of different sizes, each on its own wandering path.
    float light = 0.0;
    for (int i = 0; i < 4; i++) {
        float2 c = i == 0 ? lightsA.xy : (i == 1 ? lightsA.zw : (i == 2 ? lightsB.xy : lightsB.zw));
        float2 d = float2((uv.x - c.x) * aspect, uv.y - c.y);
        float r = i == 0 ? 0.55 : (i == 1 ? 0.42 : (i == 2 ? 0.33 : 0.62));
        float gain = i == 0 ? 1.0 : (i == 1 ? 0.85 : (i == 2 ? 0.7 : 0.6));
        light += exp(-dot(d, d) / (r * r)) * gain;
    }

    float v = (0.55 * silk + 0.35 * veil) * (0.12 + light) + 0.05 * light * light;
    v = clamp(v, 0.0, 1.0);
    return half4(half3(half(v)), 1.0h);
}

/// A faint fixed grain over the light, so its long dark gradients don't band on a big TV.
[[ stitchable ]] half4 kumoriSettingsGrain(float2 position, half4 color) {
    float n = kl_hash(floor(position) + 0.5);
    return half4(half3(half(n * 0.012)), 1.0h);
}
