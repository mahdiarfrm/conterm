/// Metal source for the liquid drop surface (`LiquidDropView`). Compiled at
/// runtime with `MTLDevice.makeLibrary(source:)` — SwiftPM's command-line
/// build does not compile `.metal` files, and an offline metallib would need
/// the separately-installed Metal toolchain on every build machine.
///
/// Two passes:
///  - `paneVS`/`paneFS` composite each visible pane's IOSurface into a
///    backdrop texture in the drop view's coordinate space.
///  - `dropVS`/`dropFS` shade the drop itself: a signed-distance body whose
///    rim stretches the backdrop like cut glass, with dispersion (the
///    spectral fringe and sheen bending light leaves, scaled per caller),
///    a frosted interior, speculars and a cast shadow.
///
/// `DropUniforms` must stay field-for-field identical to the Swift struct of
/// the same name in `LiquidDropView.swift`.
enum LiquidDropShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct DropUniforms {
        float4 view;      // width pt, height pt, backing scale, backdrop px per pt
        float4 body;      // center x, center y, half width, half height (pt)
        float4 shape;     // corner radius, ripple amplitude, ripple phase, presence
        float4 sat[3];    // satellite droplets: x, y, radius, unused
        float4 tint;      // rgb, interior strength
        float4 pointer;   // x, y, active, surface: 1 backdrop, 0 opaque, -1 sheet
        float4 misc;      // scene dim, light appearance, bevel cap pt (0 = default), dispersion 0…1
    };

    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };

    // MARK: backdrop composite

    vertex VOut paneVS(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 c = float2(float(vid & 1), float((vid >> 1) & 1));
        float2 p = mix(rect.xy, rect.zw, c);
        VOut o;
        o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
        o.uv = c;
        return o;
    }

    fragment half4 paneFS(VOut in [[stage_in]], texture2d<half> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return tex.sample(s, in.uv);
    }

    // MARK: drop

    vertex VOut dropVS(uint vid [[vertex_id]]) {
        float2 c = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(c * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(c.x, 1.0 - c.y);
        return o;
    }

    static float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // Polynomial smooth union: the neck that forms between two bodies as
    // they approach is what reads as surface tension.
    static float smin(float a, float b, float k) {
        float h = max(k - abs(a - b), 0.0) / k;
        return min(a, b) - h * h * k * 0.25;
    }

    static float field(float2 p, constant DropUniforms &u, float radius) {
        float2 hs = max(u.body.zw, float2(1.0));
        float2 q = p - u.body.xy;
        float r = min(radius, min(hs.x, hs.y));
        float d = sdRoundBox(q, hs, r);
        float amp = u.shape.y;
        if (amp > 0.01) {
            float ang = atan2(q.y / hs.y, q.x / hs.x);
            d += amp * (0.62 * sin(ang * 3.0 + u.shape.z)
                      + 0.38 * sin(ang * 5.0 - u.shape.z * 1.31));
        }
        for (int i = 0; i < 3; i++) {
            if (u.sat[i].z > 0.5) {
                d = smin(d, length(p - u.sat[i].xy) - u.sat[i].z, 34.0);
            }
        }
        return d;
    }

    static float ign(float2 px) {
        return fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));
    }

    // Jittered golden-angle disc over a mip level matched to the radius:
    // a wide, smooth frost for a handful of taps.
    static half3 frost(texture2d<half> tex, float2 p, float radius, float rot,
                       int taps, constant DropUniforms &u) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 inv = 1.0 / u.view.xy;
        float lod = clamp(log2(max(radius * u.view.w, 1.0) / 2.5), 0.0, 6.0);
        if (radius < 0.75) { return tex.sample(s, p * inv, level(lod)).rgb; }
        half3 sum = half3(0.0);
        for (int i = 0; i < taps; i++) {
            float a = rot + float(i) * 2.39996323;
            float rr = radius * sqrt((float(i) + 0.5) / float(taps));
            float2 o = float2(cos(a), sin(a)) * rr;
            sum += tex.sample(s, (p + o) * inv, level(lod)).rgb;
        }
        return sum / half(taps);
    }

    fragment half4 dropFS(VOut in [[stage_in]],
                          constant DropUniforms &u [[buffer(0)]],
                          texture2d<half> backdrop [[texture(0)]]) {
        float scale = u.view.z;
        float2 p = in.pos.xy / scale;
        float presence = u.shape.w;
        float light = u.misc.y;

        float corner = u.shape.x;
        float d = field(p, u, corner);
        if (d > 72.0) { return half4(0.0); }

        float aa = 0.75 / scale;
        float inside = 1.0 - smoothstep(-aa, aa, d);

        // Cast shadow: the same body, dropped and feathered. Only pixels
        // the body doesn't fully cover can show it.
        float shadow = 0.0;
        if (inside < 0.999) {
            float ds = field(p - float2(0.0, 16.0), u, corner);
            shadow = (light > 0.5 ? 0.20 : 0.46) * pow(saturate(1.0 - ds / 58.0), 2.4);
            // A caller may trim the view's margin below the shadow's reach;
            // feathering to nothing at the view's bounds keeps the layer's
            // rectangle from showing as a cut.
            float2 toEdge = min(p, u.view.xy - p);
            shadow *= smoothstep(0.0, 26.0, min(toEdge.x, toEdge.y));
            // A sheet rests on the window's glass and casts nothing on it.
            if (u.pointer.w < -0.5) shadow = 0.0;
        }
        if (inside <= 0.0) {
            return half4(0.0, 0.0, 0.0, half(shadow * presence));
        }

        float2 hs = u.body.zw;
        // A thin body (a search capsule) caps the bevel well below the
        // default so the rim doesn't swallow its whole height; the bend
        // scales with the cap to keep the same optical slope.
        float bevelCap = u.misc.z > 0.5 ? u.misc.z : 34.0;
        float bevel = clamp(min(hs.x, hs.y) * 0.85, min(6.0, bevelCap), bevelCap);

        // A box's interior distance creases along its diagonals once depth
        // exceeds the corner radius, which would mitre the rim like a
        // picture frame. The rest shape's corner radius is wider than the
        // bevel so silhouette and optics share one curve; the floor only
        // matters for a caller that asks for a tighter corner.
        float optic = max(corner, bevel + 4.0);
        float depth = max(-field(p, u, optic), 0.0);
        float t = saturate(depth / bevel);          // 0 at the rim, 1 in the flat
        float lens = pow(1.0 - t, 1.6);

        // Frost and tint come up over a wider band than the bevel, on a
        // quintic ease: the clear rim melts into the flat instead of
        // meeting it at a visible line.
        float fadeBand = min(max(bevel * 2.6, 46.0), max(min(hs.x, hs.y) * 0.95, bevel));
        float f = saturate(depth / fadeBand);
        f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

        // Everything that needs the surface normal lives in the bevel; the
        // flat — most of the body — skips the four extra field evaluations.
        bool rimZone = t < 0.999;
        float2 g = float2(0.0, -1.0);
        if (rimZone) {
            float e = 1.0;
            g = float2(field(p + float2(e, 0.0), u, optic) - field(p - float2(e, 0.0), u, optic),
                       field(p + float2(0.0, e), u, optic) - field(p - float2(0.0, e), u, optic));
            g = g / max(length(g), 1e-4);
        }

        float noise = ign(in.pos.xy);
        float rot = noise * 6.2831853;
        float dispersion = u.misc.w;
        // A sheet has nothing behind it to bend, so its rim is carried by
        // light alone and its body lets the window's glass through.
        bool sheet = u.pointer.w < -0.5;
        float rimGain = sheet ? 2.4 : 1.0;

        float3 col;
        if (u.pointer.w > 0.5) {
            // The curved rim looks inward, like the edge of a drop, and
            // stretches what it sees.
            float bend = 46.0 * lens * (bevelCap / 34.0);
            // Never fully sharp: even at the very edge the bent image is
            // softened, so stretched rows of text arrive as smears that
            // fade out, not as hard-ended bars.
            float radius = mix(3.0, 22.0, f);
            if (rimZone && lens > 0.002) {
                // Dispersion: each wavelength bends by a slightly different
                // amount. Sampled at five wavelengths so bright edges smear
                // into a continuous fringe instead of splitting text into
                // three coloured ghosts.
                // The same disc filter as the flat, so the two meet without
                // a seam where the bevel ends; each wavelength turns the
                // disc, so five sparse discs add up to one dense one.
                float3 acc = float3(0.0);
                for (int i = 0; i < 5; i++) {
                    float w = float(i) / 4.0;
                    float3 weight = saturate(1.0 - abs(w - float3(0.0, 0.5, 1.0)) * 2.0);
                    float2 sp = p - g * bend * mix(1.0 - 0.09 * dispersion,
                                                   1.0 + 0.11 * dispersion, w);
                    acc += float3(frost(backdrop, sp, radius, rot + float(i) * 1.2566, 5, u)) * weight;
                }
                col = acc / float3(1.5, 2.0, 1.5);
            } else {
                col = float3(frost(backdrop, p, radius, rot, 12, u));
            }
            col *= 1.0 - u.misc.x;
            float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
            col = mix(float3(luma), col, 1.1);
        } else {
            col = u.tint.rgb * (light > 0.5 ? 1.0 : 1.35);
        }

        // Clear at the rim, tinted through the flat so text holds contrast.
        float veil = mix(light > 0.5 ? 0.30 : 0.07, u.tint.w, f);
        col = mix(col, u.tint.rgb, veil);
        col += (light > 0.5 ? -0.02 : 0.035) * (1.0 - smoothstep(0.0, 260.0, p.y - (u.body.y - hs.y)));

        // The spectral sheen dispersion leaves on a curved edge, riding the
        // bevel only. Its strength is the caller's `dispersion`: present on
        // the large cards, barely there on working chrome. The pointer
        // shifts the phase, so it slides as the hand moves.
        if (rimZone && dispersion > 0.01) {
            float2 q = p - u.body.xy;
            float phase = t * 1.2 + atan2(q.y, q.x) / 3.14159265;
            if (u.pointer.z > 0.5) {
                float2 toPointer = u.pointer.xy - p;
                phase += 0.22 * dot(g, toPointer / max(length(toPointer), 1.0));
            }
            float3 film = 0.5 + 0.5 * cos(6.2831853 * (phase + float3(0.0, 0.333, 0.667)));
            col += film * pow(1.0 - t, 2.2) * dispersion * (light > 0.5 ? 0.09 : 0.15)
                 * (sheet ? 0.6 : 1.0);
        }

        // The edge is clear glass, not a painted border: no bright hairline,
        // only a faint key light from the top-leading corner and a fainter
        // caustic opposite, so the rim reads by what it bends.
        float2 L = normalize(float2(-0.55, -0.83));
        if (rimZone) {
            float band = smoothstep(0.0, 0.10, t) * (1.0 - smoothstep(0.10, 0.60, t));
            float key = pow(saturate(dot(g, L)), 2.2);
            float caustic = pow(saturate(dot(g, -L)), 3.0);
            col += band * (key * 0.16 + caustic * 0.06) * rimGain;
            if (sheet) col += pow(1.0 - t, 2.0) * 0.045;

            float hair = 1.0 - smoothstep(0.0, 1.1, abs(-d - 0.9));
            col += hair * (sheet ? 0.12 : 0.05) * saturate(dot(g, L) * 0.5 + 0.5);
        }

        if (u.pointer.z > 0.5) {
            float pd = length(p - u.pointer.xy);
            col += 0.055 * exp(-pd * pd / (170.0 * 170.0));
        }

        col += (noise - 0.5) * 0.02;
        col = saturate(col);

        float opacity = u.pointer.w > 0.5 ? 1.0 : (sheet ? mix(0.46, 0.72, f) : 0.95);
        float bodyAlpha = inside * presence * opacity;
        float alpha = bodyAlpha + shadow * presence * (1.0 - bodyAlpha);
        return half4(half3(col * bodyAlpha), half(alpha));
    }
    """
}
