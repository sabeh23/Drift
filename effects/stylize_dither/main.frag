#version 330 core
// Ordered dithering to a reduced palette, for a retro / pixel-art look.
//
// The pass runs on the clip's own pixels, before the transform scales it onto the canvas, so a
// pixel size of 1 is one source pixel. Pair it with the Transform panel's "Pixelated" switch to
// keep the dither grid crisp when the clip is scaled up.
in vec2 v_texCoord; out vec4 fragColor;
uniform sampler2D u_currentTexture; uniform vec2 u_resolution; uniform int u_frameIndex;
uniform float pattern; uniform float palette; uniform float levels; uniform float pixelSize;
uniform float spread; uniform float strength;
uniform vec3 darkColor; uniform vec3 lightColor;
uniform float brightness; uniform float contrast; uniform float animated;

// Fixed palettes, back to back: Game Boy (0, 4 entries), PICO-8 (4, 16), CGA (20, 4).
const vec3 PALETTES[24] = vec3[24](
    vec3(0.059, 0.220, 0.059), vec3(0.188, 0.384, 0.188),
    vec3(0.545, 0.675, 0.059), vec3(0.608, 0.737, 0.059),
    vec3(0.000, 0.000, 0.000), vec3(0.114, 0.169, 0.325), vec3(0.494, 0.145, 0.325),
    vec3(0.000, 0.529, 0.318), vec3(0.671, 0.322, 0.212), vec3(0.373, 0.341, 0.310),
    vec3(0.761, 0.765, 0.780), vec3(1.000, 0.945, 0.910), vec3(1.000, 0.000, 0.302),
    vec3(1.000, 0.639, 0.000), vec3(1.000, 0.925, 0.153), vec3(0.000, 0.894, 0.212),
    vec3(0.161, 0.678, 1.000), vec3(0.514, 0.463, 0.612), vec3(1.000, 0.467, 0.659),
    vec3(1.000, 0.800, 0.667),
    vec3(0.0, 0.0, 0.0), vec3(0.333, 1.0, 1.0), vec3(1.0, 0.333, 1.0), vec3(1.0, 1.0, 1.0));

// Bayer matrix of size 2^n: each coordinate bit contributes one base-4 digit, the lowest bits
// the most significant one (M2 = [[0, 2], [3, 1]] tiled recursively).
float bayer(ivec2 p, int n)
{
    int v = 0;
    for (int i = 0; i < n; ++i) {
        int x = (p.x >> i) & 1;
        int y = (p.y >> i) & 1;
        v = v * 4 + (((x ^ y) << 1) | y);
    }
    // Bit 0 is read first, so the loop multiplies its digit up the most: 4^(n-1), as required.
    float cells = float(1 << (2 * n));
    return (float(v) + 0.5) / cells;
}

// Interleaved gradient noise: cheap, evenly spread, no visible tiling.
float ign(vec2 p)
{
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// Threshold in [0, 1); 0.5 means "no bias".
float threshold(ivec2 cell)
{
    int mode = int(pattern + 0.5);
    if (mode == 0) return bayer(cell, 1);
    if (mode == 1) return bayer(cell, 2);
    if (mode == 2) return bayer(cell, 3);
    if (mode == 3) {
        vec2 offset = animated > 0.5 ? vec2(float(u_frameIndex % 64) * 5.588238) : vec2(0.0);
        return ign(vec2(cell) + offset);
    }
    if (mode == 4) return (float(cell.y & 3) + 0.5) / 4.0;
    return 0.5;
}

// Quantize each value to `steps` evenly spaced levels, nudged by the threshold.
vec3 quantize(vec3 c, float steps, float t)
{
    float n = max(steps - 1.0, 1.0);
    return clamp(floor(c * n + 0.5 + (t - 0.5) * spread), 0.0, n) / n;
}

// Ordered dithering against an arbitrary palette: take the two nearest entries and pick between
// them by how far the colour sits along the line joining them.
vec3 mixPair(vec3 c, vec3 a, vec3 b, float t)
{
    vec3 ab = b - a;
    float denom = max(dot(ab, ab), 1e-6);
    float f = clamp(dot(c - a, ab) / denom, 0.0, 1.0);
    float bias = (t - 0.5) * spread;
    return (f + bias) > 0.5 ? b : a;
}

vec3 toPalette(vec3 c, float t, int first, int count)
{
    float d1 = 1e9;
    float d2 = 1e9;
    int i1 = first;
    int i2 = first;
    for (int i = first; i < first + count; ++i) {
        vec3 d = c - PALETTES[i];
        float dist = dot(d, d);
        if (dist < d1) {
            d2 = d1; i2 = i1;
            d1 = dist; i1 = i;
        } else if (dist < d2) {
            d2 = dist; i2 = i;
        }
    }
    return mixPair(c, PALETTES[i1], PALETTES[i2], t);
}

void main()
{
    vec4 src = texture(u_currentTexture, v_texCoord);
    float s = clamp(strength, 0.0, 1.0);
    if (s <= 1e-5) {
        fragColor = src;
        return;
    }

    // Chunky pixels: every pixel in a cell takes the cell's centre colour and one threshold.
    float px = max(floor(pixelSize + 0.5), 1.0);
    vec2 coord = v_texCoord * u_resolution;
    ivec2 cell = ivec2(floor(coord / px));
    vec2 centreUv = (vec2(cell) + 0.5) * px / u_resolution;
    vec4 cellSrc = px > 1.0 ? texture(u_currentTexture, centreUv) : src;

    // The source is premultiplied: dither the straight colour, then premultiply again.
    float alpha = cellSrc.a;
    vec3 c = cellSrc.rgb / max(alpha, 1e-5);
    c = clamp((c - 0.5) * contrast + 0.5 + brightness, 0.0, 1.0);

    float t = threshold(cell);
    int pal = int(palette + 0.5);
    vec3 outColor;
    if (pal == 0) {
        outColor = quantize(c, levels, t);
    } else if (pal == 1) {
        float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
        outColor = quantize(vec3(lum), levels, t);
    } else if (pal == 2) {
        outColor = mixPair(c, darkColor, lightColor, t);
    } else if (pal == 3) {
        outColor = toPalette(c, t, 0, 4);
    } else if (pal == 4) {
        outColor = toPalette(c, t, 4, 16);
    } else {
        outColor = toPalette(c, t, 20, 4);
    }

    vec3 straight = mix(src.rgb / max(src.a, 1e-5), outColor, s);
    float a = mix(src.a, alpha, s);
    fragColor = vec4(straight * a, a);
}
