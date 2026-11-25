#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut triangle_vertex(uint vid [[vertex_id]],
                                 constant float &angle [[buffer(0)]]) {
    const float2 pos[3] = {
        float2( 0.00,  0.65),
        float2(-0.65, -0.55),
        float2( 0.65, -0.55)
    };
    const float3 col[3] = {
        float3(1.0, 0.25, 0.30),
        float3(0.20, 0.95, 0.45),
        float3(0.25, 0.55, 1.0)
    };
    float c = cos(angle);
    float s = sin(angle);
    float2 p = pos[vid];
    float2 rot = float2(p.x * c - p.y * s, p.x * s + p.y * c);

    VertexOut out;
    out.position = float4(rot, 0.0, 1.0);
    out.color = col[vid];
    return out;
}

fragment float4 triangle_fragment(VertexOut in [[stage_in]],
                                  constant float &hue [[buffer(0)]]) {
    float3 shifted = in.color.zxy * hue + in.color * (1.0 - hue);
    return float4(shifted, 1.0);
}
