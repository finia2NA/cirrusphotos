import CoreGraphics
import CoreImage
import Foundation
import Metal

/// An image effect owns its shader and additional arguments. The renderer owns
/// color conversion, bounded sampling, scheduling, GPU resources and readback.
/// Identifiers must uniquely identify the shader and function for pipeline caching.
protocol ViewerGPUImageEffect {
    var identifier: String { get }
    var shaderSource: String { get }
    var functionName: String { get }
    func encodeArguments(on encoder: MTLComputeCommandEncoder)
}
/// Core Image performs the bounded, color-managed resampling; a small Metal kernel
/// classifies its samples and writes the mask. One renderer serializes GPU work so
/// cancelled, superseded requests are discarded before starting and before publishing.
final class ViewerGPUImageRenderer: @unchecked Sendable {
    static let shared = ViewerGPUImageRenderer()
    private let lock = NSLock()
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let context: CIContext?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let colorSpace: CGColorSpace

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        colorSpace = space
        self.device = device
        queue = device?.makeCommandQueue()
        context = device.map { CIContext(mtlDevice: $0, options: [.workingColorSpace: space,
                                                                   .outputColorSpace: space,
                                                                   .cacheIntermediates: false]) }
    }

    private func pipeline(for effect: some ViewerGPUImageEffect, device: MTLDevice) -> MTLComputePipelineState? {
        if let cached = pipelines[effect.identifier] { return cached }
        guard let library = try? device.makeLibrary(source: effect.shaderSource, options: nil),
              let function = library.makeFunction(name: effect.functionName),
              let compiled = try? device.makeComputePipelineState(function: function) else { return nil }
        pipelines[effect.identifier] = compiled
        return compiled
    }

    func render(_ image: CGImage, effect: some ViewerGPUImageEffect, maximumDimension: Int) -> CGImage? {
        guard image.width > 0, image.height > 0, maximumDimension > 0, !Task.isCancelled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled, let device, let queue, let context else { return nil }
        guard let pipeline = pipeline(for: effect, device: device) else { return nil }
        // Four samples per mask pixel when reduced. Higher-depth images use a
        // smaller sample budget to bound 32-bit float texture cost.
        let longest = max(image.width, image.height)
        let dimensionScale = Double(min(maximumDimension, 2048)) / Double(longest)
        let overlayPixelBudget = image.bitsPerComponent <= 8 ? 2_500_000.0 : 1_000_000.0
        let areaScale = sqrt(overlayPixelBudget / (Double(image.width) * Double(image.height)))
        let scale = min(1, dimensionScale, areaScale)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var samplesPerAxis: UInt32 = scale < 1 ? 2 : 1
        let sampleWidth = width * Int(samplesPerAxis), sampleHeight = height * Int(samplesPerAxis)
        // Half floats preserve 8-bit source steps; keep full floats for higher-depth
        // inputs so near-white values are not rounded up to the clipping threshold.
        let inputFormat: MTLPixelFormat = image.bitsPerComponent <= 8 ? .rgba16Float : .rgba32Float
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: inputFormat,
                            width: sampleWidth, height: sampleHeight, mipmapped: false)
        inputDescriptor.usage = [.shaderRead, .shaderWrite]
        inputDescriptor.storageMode = .private
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                            width: width, height: height, mipmapped: false)
        outputDescriptor.usage = [.shaderWrite]
        outputDescriptor.storageMode = .shared
        guard let input = device.makeTexture(descriptor: inputDescriptor),
              let output = device.makeTexture(descriptor: outputDescriptor),
              let command = queue.makeCommandBuffer() else { return nil }
        let resized = CIImage(cgImage: image).transformed(by: CGAffineTransform(
            scaleX: CGFloat(sampleWidth) / CGFloat(image.width),
            y: CGFloat(sampleHeight) / CGFloat(image.height)))
        context.render(resized, to: input, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
                       colorSpace: colorSpace)
        guard !Task.isCancelled, let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&samplesPerAxis, length: MemoryLayout<UInt32>.size, index: 0)
        effect.encodeArguments(on: encoder)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard !Task.isCancelled, command.status == .completed else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&pixels, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels.withUnsafeMutableBufferPointer { buffer in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return bitmap.makeImage()
        }
    }
}
