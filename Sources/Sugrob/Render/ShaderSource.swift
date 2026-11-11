/// Metal shaders, compiled at runtime with `device.makeLibrary(source:options:)` because
/// SwiftPM on the command line does not compile `.metal` files.
///
/// All positions arrive in screen-local points (origin top-left, y grows down) and are
/// converted to NDC with the viewport size. Fragments return premultiplied alpha.
///
/// The structs here must match `FlakeInstance`, `DriftVertex`, `ShapeInstance` and
/// `RenderUniforms` in `SnowRenderer.swift` byte for byte.
enum ShaderSource {
    static let flakeVertex = "flake_vertex"
    static let flakeFragment = "flake_fragment"
    static let driftVertex = "drift_vertex"
    static let driftFragment = "drift_fragment"
    static let occluderFragment = "occluder_fragment"
    static let shapeVertex = "shape_vertex"
    static let shapeFragment = "shape_fragment"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewportSize;
    };

    static float4 to_clip(float2 p, float2 viewport) {
        float2 ndc = float2(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0);
        return float4(ndc, 0.0, 1.0);
    }

    // MARK: Flakes

    struct FlakeInstance {
        float2 position;
        float size;
        float opacity;
        float rotation;
        float lumpiness;
    };

    struct FlakeOut {
        float4 position [[position]];
        float2 uv;
        float opacity;
        float lumpiness;
    };

    // Instanced quad drawn as a 4-vertex triangle strip. The quad is 1.5x the flake
    // diameter so the soft falloff has room; uv is -1...1 in the flake's rotated frame.
    vertex FlakeOut flake_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device FlakeInstance *instances [[buffer(0)]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        FlakeInstance f = instances[iid];
        float2 corner = float2((vid & 1u) != 0u ? 1.0 : -1.0, (vid & 2u) != 0u ? 1.0 : -1.0);
        float c = cos(f.rotation);
        float s = sin(f.rotation);
        float extent = max(f.size, 1.0) * 0.75;
        float2 offset = float2(c * corner.x - s * corner.y, s * corner.x + c * corner.y) * extent;

        FlakeOut out;
        out.position = to_clip(f.position + offset, uniforms.viewportSize);
        out.uv = corner;
        out.opacity = f.opacity;
        out.lumpiness = f.lumpiness;
        return out;
    }

    fragment float4 flake_fragment(FlakeOut in [[stage_in]]) {
        float r = length(in.uv);
        float angle = atan2(in.uv.y, in.uv.x);
        // Clumps knocked off a drift are slightly irregular; plain flakes are round.
        float lump = 1.0 + in.lumpiness * (0.12 * sin(angle * 3.0) + 0.07 * sin(angle * 5.0 + 1.3));
        float radius = min(0.667 * lump, 0.95);
        float inner = radius * mix(0.3, 0.65, in.lumpiness);
        float core = 1.0 - smoothstep(inner, radius, r);
        float halo = (1.0 - smoothstep(0.0, 1.0, r)) * 0.15;
        float a = saturate(max(core, halo) * in.opacity);
        float3 color = float3(0.97, 0.98, 1.0);
        return float4(color * a, a);
    }

    // MARK: Drifts

    // dist: points below the top of the bank (0 on the top edge).
    // t: -1 at the outer edge of the anti-aliasing feather, 0 on the top edge, 1 at the base.
    struct DriftVertex {
        float2 position;
        float dist;
        float t;
    };

    struct DriftOut {
        float4 position [[position]];
        float dist;
        float t;
    };

    vertex DriftOut drift_vertex(uint vid [[vertex_id]],
                                 const device DriftVertex *vertices [[buffer(0)]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        DriftVertex v = vertices[vid];
        DriftOut out;
        out.position = to_clip(v.position, uniforms.viewportSize);
        out.dist = v.dist;
        out.t = v.t;
        return out;
    }

    fragment float4 drift_fragment(DriftOut in [[stage_in]]) {
        float alpha = in.t < 0.0 ? saturate(1.0 + in.t) : 1.0;
        float t = saturate(in.t);
        float3 top = float3(0.96, 0.975, 1.0);
        float3 base = float3(0.73, 0.79, 0.89);
        float3 color = mix(top, base, smoothstep(0.2, 1.0, t));
        // Bright rim along the top edge.
        float rim = 1.0 - smoothstep(0.0, 2.5, max(in.dist, 0.0));
        color = mix(color, float3(1.0), rim * 0.85);
        return float4(color * alpha, alpha);
    }

    // Writes only the stencil buffer (color write mask is empty).
    fragment float4 occluder_fragment(DriftOut in [[stage_in]]) {
        return float4(0.0);
    }

    // MARK: Shapes (snowballs, snowmen, shovel, clumps)

    // kind: 0 shaded snowball, 1 flat disc, 2 triangle pointing +x, 3 rounded bar,
    // 4 lumpy snow blob (ellipse). size is the half extent in points.
    struct ShapeInstance {
        float2 center;
        float2 size;
        float4 color;
        float rotation;
        float kind;
        float seed;
        float pad;
    };

    struct ShapeOut {
        float4 position [[position]];
        float2 local;
        float2 size [[flat]];
        float4 color [[flat]];
        float kind [[flat]];
        float seed [[flat]];
    };

    vertex ShapeOut shape_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device ShapeInstance *instances [[buffer(0)]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        ShapeInstance s = instances[iid];
        float2 corner = float2((vid & 1u) != 0u ? 1.0 : -1.0, (vid & 2u) != 0u ? 1.0 : -1.0);
        // One and a half points of room for the anti-aliased edge (and the blob's lumps).
        float2 extent = s.size * (s.kind > 3.5 ? 1.25 : 1.0) + 1.5;
        float2 local = corner * extent;
        float c = cos(s.rotation);
        float n = sin(s.rotation);
        float2 offset = float2(c * local.x - n * local.y, n * local.x + c * local.y);

        ShapeOut out;
        out.position = to_clip(s.center + offset, uniforms.viewportSize);
        out.local = local;
        out.size = max(s.size, float2(0.5));
        out.color = s.color;
        out.kind = s.kind;
        out.seed = s.seed;
        return out;
    }

    // n: point on the ball, -1...1, y down. Lit from the upper left, blue-grey below.
    static float3 snow_shade(float2 n) {
        float toward = dot(n, float2(-0.45, -0.89));
        float shadow = smoothstep(-0.35, 1.0, -toward);
        float3 lit = float3(0.99, 0.995, 1.0);
        float3 dark = float3(0.70, 0.76, 0.86);
        return mix(lit, dark, shadow * 0.8);
    }

    fragment float4 shape_fragment(ShapeOut in [[stage_in]]) {
        float2 p = in.local;
        float2 size = in.size;
        float3 color = in.color.rgb;
        float d;
        int kind = int(in.kind + 0.5);

        if (kind == 0) {
            d = length(p) - size.x;
            color = snow_shade(p / size.x);
            // Soft blue-grey outline so the ball reads on white backgrounds.
            color = mix(color, float3(0.62, 0.69, 0.80), smoothstep(-1.8, 0.0, d) * 0.55);
        } else if (kind == 1) {
            d = length(p) - size.x;
        } else if (kind == 2) {
            float halfHeight = size.y * (size.x - p.x) / (2.0 * size.x);
            float slope = size.y / (2.0 * size.x);
            float side = (abs(p.y) - halfHeight) / sqrt(1.0 + slope * slope);
            d = max(side, -size.x - p.x);
            color *= mix(1.0, 0.78, saturate(p.y / size.y * 0.5 + 0.5));
        } else if (kind == 3) {
            float r = min(size.x, size.y);
            float2 q = abs(p) - size + r;
            d = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
            color *= 1.0 - 0.2 * saturate(p.y / size.y * 0.5 + 0.5);
        } else {
            float2 q = p / size;
            float r = length(q);
            float angle = atan2(q.y, q.x);
            float lump = 1.0 + 0.09 * sin(angle * 3.0 + in.seed)
                             + 0.06 * sin(angle * 5.0 + in.seed * 1.7)
                             + 0.04 * sin(angle * 8.0 + in.seed * 2.3);
            d = (r - lump) * min(size.x, size.y);
            color = snow_shade(q / lump);
            color = mix(color, float3(0.66, 0.72, 0.83), smoothstep(-1.6, 0.0, d) * 0.45);
        }

        float coverage = 1.0 - smoothstep(-0.75, 0.75, d);
        float a = saturate(coverage * in.color.a);
        return float4(color * a, a);
    }
    """
}
