import CoreGraphics
import CoreImage
import Foundation
import Metal

/// How the renderer prepares an effect's input texture.
enum ViewerGPUImageInput {
    /// Color samples reduced to a bounded overlay, with 2×2 samples per overlay pixel when scaled.
    case reducedColor
    /// One luminance channel at up to `maximumPixels` (and 16384 pixels per side). The overlay is pooled
    /// from it by an integer block, passed to the shader as `buffer(0)`, so detail is not averaged away first.
    case luminance(maximumPixels: Int)
}

/// An image effect owns its shader and additional arguments. The renderer owns
/// color conversion, bounded sampling, scheduling, GPU resources and readback.
/// Identifiers must uniquely identify the shader and function for pipeline caching.
protocol ViewerGPUImageEffect {
    var identifier: String { get }
    var shaderSource: String { get }
    var functionName: String { get }
    var input: ViewerGPUImageInput { get }
    /// Optional whole-input pass that runs before the main function and fills a zeroed buffer of
    /// `statisticsBinCount` unsigned integers, bound as `buffer(2)` to both functions. Its kernel is
    /// dispatched in full 16×16 threadgroups over the input texture and must bounds-check.
    var statisticsFunctionName: String? { get }
    var statisticsBinCount: Int { get }
    func encodeArguments(on encoder: MTLComputeCommandEncoder)
}
extension ViewerGPUImageEffect {
    var input: ViewerGPUImageInput { .reducedColor }
    var statisticsFunctionName: String? { nil }
    var statisticsBinCount: Int { 0 }
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

    private func pipeline(for effect: some ViewerGPUImageEffect, function name: String,
                          device: MTLDevice) -> MTLComputePipelineState? {
        let key = "\(effect.identifier)/\(name)"
        if let cached = pipelines[key] { return cached }
        guard let library = try? device.makeLibrary(source: effect.shaderSource, options: nil),
              let function = library.makeFunction(name: name),
              let compiled = try? device.makeComputePipelineState(function: function) else { return nil }
        pipelines[key] = compiled
        return compiled
    }

    func render(_ image: CGImage, effect: some ViewerGPUImageEffect, maximumDimension: Int) -> CGImage? {
        guard image.width > 0, image.height > 0, maximumDimension > 0, !Task.isCancelled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled, let device, let queue, let context else { return nil }
        guard let mainPipeline = pipeline(for: effect, function: effect.functionName, device: device) else { return nil }
        var statistics: (pipeline: MTLComputePipelineState, buffer: MTLBuffer)?
        if let name = effect.statisticsFunctionName {
            guard let statisticsPipeline = pipeline(for: effect, function: name, device: device),
                  let buffer = device.makeBuffer(length: max(4, effect.statisticsBinCount * 4),
                                                 options: .storageModeShared) else { return nil }
            memset(buffer.contents(), 0, buffer.length)
            statistics = (statisticsPipeline, buffer)
        }
        let width: Int, height: Int, sampleWidth: Int, sampleHeight: Int
        var samplesPerAxis: UInt32
        let inputFormat: MTLPixelFormat
        let overlayLimit = min(maximumDimension, 2048)
        let luminancePixelScale: Double?
        switch effect.input {
        case .reducedColor:
            // Four samples per mask pixel when reduced. Higher-depth images use a
            // smaller sample budget to bound 32-bit float texture cost.
            let longest = max(image.width, image.height)
            let dimensionScale = Double(overlayLimit) / Double(longest)
            let overlayPixelBudget = image.bitsPerComponent <= 8 ? 2_500_000.0 : 1_000_000.0
            let areaScale = sqrt(overlayPixelBudget / (Double(image.width) * Double(image.height)))
            let scale = min(1, dimensionScale, areaScale)
            width = max(1, Int(Double(image.width) * scale))
            height = max(1, Int(Double(image.height) * scale))
            samplesPerAxis = scale < 1 ? 2 : 1
            sampleWidth = width * Int(samplesPerAxis)
            sampleHeight = height * Int(samplesPerAxis)
            // Half floats preserve 8-bit source steps; keep full floats for higher-depth
            // inputs so near-white values are not rounded up to the clipping threshold.
            inputFormat = image.bitsPerComponent <= 8 ? .rgba16Float : .rgba32Float
            luminancePixelScale = nil
        case .luminance(let maximumPixels):
            let scale = min(1, sqrt(Double(maximumPixels) / (Double(image.width) * Double(image.height))),
                            16384 / Double(max(image.width, image.height)))
            sampleWidth = max(1, Int(Double(image.width) * scale))
            sampleHeight = max(1, Int(Double(image.height) * scale))
            let block = max(1, Int((Double(max(sampleWidth, sampleHeight)) / Double(overlayLimit)).rounded(.up)))
            samplesPerAxis = UInt32(block)
            width = (sampleWidth + block - 1) / block
            height = (sampleHeight + block - 1) / block
            inputFormat = .r16Float
            luminancePixelScale = scale
        }
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
        var resized = CIImage(cgImage: image)
        if let luminancePixelScale {
            if luminancePixelScale < 1 {
                resized = resized.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: Double(sampleHeight) / Double(image.height), kCIInputAspectRatioKey:
                        (Double(sampleWidth) / Double(image.width)) / (Double(sampleHeight) / Double(image.height))])
            }
            resized = resized.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        } else {
            resized = resized.transformed(by: CGAffineTransform(
                scaleX: CGFloat(sampleWidth) / CGFloat(image.width),
                y: CGFloat(sampleHeight) / CGFloat(image.height)))
        }
        context.render(resized, to: input, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
                       colorSpace: colorSpace)
        guard !Task.isCancelled, let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setTexture(input, index: 0)
        if let statistics {
            encoder.setComputePipelineState(statistics.pipeline)
            encoder.setBuffer(statistics.buffer, offset: 0, index: 2)
            encoder.dispatchThreadgroups(MTLSize(width: (sampleWidth + 15) / 16, height: (sampleHeight + 15) / 16, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.setComputePipelineState(mainPipeline)
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
