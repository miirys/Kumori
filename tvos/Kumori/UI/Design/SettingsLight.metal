#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Settings' background: white light moving through dark smoke, on black. Folded noise makes
// the smoke, and three soft lights wander through it on paths taken from noise too, so the
// light never runs on a loop. Only shades of white.

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
    for (int i = 0; i < 5; i++) {
        s += a * kl_noise(p);
        p = float2(1.6 * p.x - 1.2 * p.y, 1.2 * p.x + 1.6 * p.y);
        a *= 0.5;
    }
    return s;
}

/// `size` is the view's size in points, `time` seconds.
[[ stitchable ]] half4 kumoriSettingsLight(float2 position, half4 color, float2 size, float time) {
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2(uv.x * aspect, uv.y) * 1.4;
    float t = time;

    // The smoke: noise folded through itself twice, each fold drifting its own way.
    float2 q = float2(kl_fbm(p + float2(0.03 * t, 0.0)),
                      kl_fbm(p + float2(5.2, 1.3 - 0.025 * t)));
    float2 r = float2(kl_fbm(p + 3.0 * q + float2(1.7 + 0.05 * t, 9.2)),
                      kl_fbm(p + 3.0 * q + float2(8.3, 2.8 - 0.04 * t)));
    float f = kl_fbm(p + 3.0 * r);
    float silk = smoothstep(0.30, 0.85, f);
    silk *= silk;
    float folds = clamp(length(r - q) * 1.2, 0.0, 1.0);

    // Three lights, each on its own wandering path.
    float light = 0.0;
    for (int i = 0; i < 3; i++) {
        float k = float(i);
        float2 c = float2(kl_noise(float2(t * 0.045 + k * 17.0, k * 3.7)),
                          kl_noise(float2(k * 5.1, t * 0.04 + k * 29.0)));
        c = (c - 0.5) * 1.6 + 0.5;
        float2 d = float2((uv.x - c.x) * aspect, uv.y - c.y);
        float rad = 0.42 + 0.12 * k;
        light += exp(-dot(d, d) / (rad * rad)) * (1.0 - 0.25 * k);
    }

    float v = silk * (0.22 + light) * (0.55 + 0.7 * folds) + 0.07 * light * light;
    v = clamp(v, 0.0, 1.0);
    return half4(half3(half(v)), 1.0h);
}

/// A faint fixed grain over the light, so its long dark gradients don't band on a big TV.
[[ stitchable ]] half4 kumoriSettingsGrain(float2 position, half4 color) {
    float n = kl_hash(floor(position) + 0.5);
    return half4(half3(half(n * 0.012)), 1.0h);
}
