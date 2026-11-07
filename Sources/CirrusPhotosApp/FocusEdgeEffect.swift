import Metal

/// Relative sharp-edge classification on a luminance channel of up to 20 megapixels. A pixel's edge
/// width is its local contrast ÷ its Sobel slope, which does not depend on edge contrast. Only
/// gradient ridges that belong to a line qualify: the 5×5 gradient structure tensor must be
/// directional (coherence ≥ 0.6) and at least 10 of the 16 pixels within 8 along the edge must
/// continue it, so isolated dots and fine texture such as pile or noise are dropped. A first
/// pass histograms the widths of the remaining edge pixels; the reference is the 10th-percentile
/// width, the image's own sharpest edges, and pixels with a width up to `widthTolerance` times
/// that are marked. The result is relative to the image: it shows where focus is best, not
/// whether it is good.
struct FocusEdgeEffect: ViewerGPUImageEffect {
    static let maximumPixels = 20_000_000
    static let binCount = 64
    let widthTolerance: Float
    let identifier = "focus-edges"
    let functionName = "focus_edges"
    let statisticsFunctionName: String? = "focus_edge_statistics"
    var statisticsBinCount: Int { Self.binCount }
    var input: ViewerGPUImageInput { .luminance(maximumPixels: Self.maximumPixels) }
    let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    constant uint binCount = 64;

    static float luma_at(texture2d<float, access::read> input, int2 q) {
        const int2 last = int2(input.get_width(), input.get_height()) - 1;
        return input.read(uint2(clamp(q, int2(0), last))).r;
    }

    // Sobel gradient in luminance per pixel.
    static float2 gradient(texture2d<float, access::read> input, int2 c) {
        float tl = luma_at(input, c + int2(-1, -1)), t = luma_at(input, c + int2(0, -1)), tr = luma_at(input, c + int2(1, -1));
        float l = luma_at(input, c + int2(-1, 0)), r = luma_at(input, c + int2(1, 0));
        float bl = luma_at(input, c + int2(-1, 1)), b = luma_at(input, c + int2(0, 1)), br = luma_at(input, c + int2(1, 1));
        return float2((tr + 2 * r + br) - (tl + 2 * l + bl), (bl + 2 * b + br) - (tl + 2 * t + tr)) * 0.125f;
    }

    // Edge width in pixels at a one-pixel-wide ridge of the gradient, or -1 elsewhere.
    static float edge_width(texture2d<float, access::read> input, int2 c) {
        const float minimumSlope = 0.03f, minimumContrast = 0.08f;
        float2 g = gradient(input, c);
        float slope = length(g);
        if (slope < minimumSlope) return -1;
        int2 step = int2(round(g / slope));
        if (slope < length(gradient(input, c + step)) || slope <= length(gradient(input, c - step))) return -1;
        { // Directional: one dominant gradient orientation around the pixel.
            float jxx = 0, jyy = 0, jxy = 0;
            for (int dy = -2; dy <= 2; ++dy) {
                for (int dx = -2; dx <= 2; ++dx) {
                    float2 q = gradient(input, c + int2(dx, dy));
                    jxx += q.x * q.x; jyy += q.y * q.y; jxy += q.x * q.y;
                }
            }
            float coherence = sqrt((jxx - jyy) * (jxx - jyy) + 4 * jxy * jxy) / max(jxx + jyy, 1e-6f);
            if (coherence < 0.6f) return -1;
        }
        { // Continuing: neighbours along the edge share its slope and orientation.
            float2 tangent = float2(-g.y, g.x) / slope;
            int support = 0;
            const int reach = 8, needed = 10;
            for (int k = -reach; k <= reach; ++k) {
                if (k == 0) continue;
                float2 h = gradient(input, c + int2(round(tangent * float(k))));
                float m = length(h);
                if (m >= 0.5f * slope && dot(h, g) / (m * slope) > 0.8f) ++support;
            }
            if (support < needed) return -1;
        }
        float lo = luma_at(input, c), hi = lo;
        for (int dy = -4; dy <= 4; dy += 2) {
            for (int dx = -4; dx <= 4; dx += 2) {
                float v = luma_at(input, c + int2(dx, dy));
                lo = min(lo, v); hi = max(hi, v);
            }
        }
        float contrast = hi - lo;
        return contrast >= minimumContrast ? contrast / slope : -1;
    }

    // Six bins per octave from 0.25 px.
    static uint width_bin(float width) {
        return uint(clamp(log2(width * 4.0f) * 6.0f, 0.0f, float(binCount - 1)));
    }

    kernel void focus_edge_statistics(texture2d<float, access::read> input [[texture(0)]],
                                      device atomic_uint *histogram [[buffer(2)]],
                                      uint2 p [[thread_position_in_grid]],
                                      uint local [[thread_index_in_threadgroup]]) {
        threadgroup atomic_uint bins[binCount];
        if (local < binCount) atomic_store_explicit(&bins[local], 0, memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (p.x < input.get_width() && p.y < input.get_height()) {
            float width = edge_width(input, int2(p));
            if (width > 0) atomic_fetch_add_explicit(&bins[width_bin(width)], 1, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (local < binCount) {
            atomic_fetch_add_explicit(&histogram[local], atomic_load_explicit(&bins[local], memory_order_relaxed),
                                      memory_order_relaxed);
        }
    }

    kernel void focus_edges(texture2d<float, access::read> input [[texture(0)]],
                            texture2d<float, access::write> output [[texture(1)]],
                            constant uint &block [[buffer(0)]],
                            constant float &widthTolerance [[buffer(1)]],
                            device const uint *histogram [[buffer(2)]],
                            uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        uint edges = 0;
        for (uint i = 0; i < binCount; ++i) edges += histogram[i];
        float limit = -1;
        if (edges >= 256) {
            uint cumulative = 0, reference = 0;
            for (; reference < binCount - 1; ++reference) {
                cumulative += histogram[reference];
                if (cumulative * 10 >= edges) break;
            }
            limit = 0.25f * exp2(float(reference + 1) / 6.0f) * widthTolerance;
        }
        const int height = int(input.get_height());
        uint covered = 0, total = 0;
        for (uint y = 0; y < block; ++y) {
            for (uint x = 0; x < block; ++x) {
                uint2 sample = p * block + uint2(x, y);
                if (sample.x >= input.get_width() || sample.y >= input.get_height()) continue;
                ++total;
                float width = edge_width(input, int2(sample.x, height - 1 - int(sample.y)));
                if (width > 0 && width <= limit) ++covered;
            }
        }
        float coverage = total == 0 ? 0 : saturate(2.0f * float(covered) / float(total));
        output.write(float4(0.1f * coverage, coverage, 0.3f * coverage, coverage), p);
    }
    """

    func encodeArguments(on encoder: MTLComputeCommandEncoder) {
        var tolerance = widthTolerance
        encoder.setBytes(&tolerance, length: MemoryLayout<Float>.size, index: 1)
    }
}
