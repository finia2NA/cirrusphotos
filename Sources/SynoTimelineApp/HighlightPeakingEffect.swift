import Metal

/// Near-neutral white highlight classification in the renderer's extended sRGB samples.
struct HighlightPeakingEffect: ViewerGPUImageEffect {
    let threshold: Float
    let identifier = "highlight-peaking"
    let functionName = "highlight_mask"
    let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void highlight_mask(texture2d<float, access::read> input [[texture(0)]],
                               texture2d<float, access::write> output [[texture(1)]],
                               constant uint &samplesPerAxis [[buffer(0)]],
                               constant float &threshold [[buffer(1)]],
                               uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        uint covered = 0;
        for (uint y = 0; y < samplesPerAxis; ++y) {
            for (uint x = 0; x < samplesPerAxis; ++x) {
                uint2 sample = p * samplesPerAxis + uint2(x, y);
                sample.y = input.get_height() - 1 - sample.y;
                float4 color = input.read(sample);
                float brightest = max(color.r, max(color.g, color.b));
                float darkest = min(color.r, min(color.g, color.b));
                if (color.a > 0 && brightest >= (threshold - 0.000001f) * color.a &&
                    darkest >= brightest * 0.95f) ++covered;
            }
        }
        float coverage = float(covered) / float(samplesPerAxis * samplesPerAxis);
        output.write(float4(coverage, 0, 0, coverage), p);
    }
    """

    func encodeArguments(on encoder: MTLComputeCommandEncoder) {
        var minimum = threshold
        encoder.setBytes(&minimum, length: MemoryLayout<Float>.size, index: 1)
    }
}
