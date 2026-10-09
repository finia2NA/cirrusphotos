import CoreGraphics
import Foundation
import ImageIO
import SynologyAPI

struct ThumbnailOrientationMatch: Sendable, Equatable {
    let clockwiseQuarterTurns: Int
    let scoresBySize: [ThumbnailSize: [Double]]
}

enum ThumbnailOrientationMatchError: LocalizedError, Equatable, Sendable {
    case undecodableOriginal
    case undecodableThumbnail(ThumbnailSize)
    case ambiguous(ThumbnailSize)
    case disagreement([ThumbnailSize: Int])

    var errorDescription: String? {
        switch self {
        case .undecodableOriginal:
            "The full-size image could not be decoded by ImageIO."
        case .undecodableThumbnail(let size):
            "The \(size.rawValue) thumbnail could not be decoded by ImageIO."
        case .ambiguous(let size):
            "The \(size.rawValue) thumbnail rotation could not be determined confidently."
        case .disagreement:
            "The sm, m, and xl thumbnails did not agree on one rotation."
        }
    }
}

actor ThumbnailOrientationAnalyzer {
    static let shared = ThumbnailOrientationAnalyzer()

    func match(originalData: Data, item: PhotoItem,
               thumbnails: [ThumbnailSize: Data]) throws -> ThumbnailOrientationMatch {
        try ThumbnailOrientationMatcher.match(
            originalData: originalData, item: item, thumbnails: thumbnails
        )
    }
}

/// Compares small, orientation-normalized luminance rasters. ImageIO performs the
/// format-specific decode (including HEIC/HIF, JPEG, PNG, and TIFF) while this type
/// remains concerned only with relative quarter-turn orientation.
enum ThumbnailOrientationMatcher {
    private struct ComparisonRaster {
        let width: Int
        let height: Int
        let pixels: [Double]
    }

    private static let maximumPixelSize = 256
    private static let comparisonLongSide = 128
    private static let aspectTolerance = 0.035
    private static let maximumAcceptedScore = 0.22
    private static let minimumRunnerUpMargin = 0.12

    static func match(
        originalData: Data,
        item: PhotoItem,
        thumbnails: [ThumbnailSize: Data]
    ) throws -> ThumbnailOrientationMatch {
        guard let decodedOriginal = decode(originalData) else {
            throw ThumbnailOrientationMatchError.undecodableOriginal
        }
        let reference = try rotate(decodedOriginal, clockwiseQuarterTurns: item.originalDisplayQuarterTurns)
        let referenceRaster = try raster(reference)
        var winners: [ThumbnailSize: Int] = [:]
        var allScores: [ThumbnailSize: [Double]] = [:]

        for size in ThumbnailSize.allCases {
            guard let data = thumbnails[size], let thumbnail = decode(data) else {
                throw ThumbnailOrientationMatchError.undecodableThumbnail(size)
            }
            var scores = Array(repeating: Double.infinity, count: 4)
            for turns in 0..<4 {
                let candidate = try rotate(thumbnail, clockwiseQuarterTurns: turns)
                guard aspectMatches(reference, candidate) else { continue }
                scores[turns] = try score(
                    referenceRaster,
                    raster(candidate, width: referenceRaster.width, height: referenceRaster.height)
                )
            }
            allScores[size] = scores
            let ranked = scores.enumerated()
                .filter { $0.element.isFinite }
                .sorted { $0.element < $1.element }
            guard ranked.count >= 2,
                  ranked[0].element <= maximumAcceptedScore,
                  ranked[1].element - ranked[0].element >= minimumRunnerUpMargin else {
                throw ThumbnailOrientationMatchError.ambiguous(size)
            }
            winners[size] = ranked[0].offset
        }

        let distinct = Set(winners.values)
        guard distinct.count == 1, let winner = distinct.first else {
            throw ThumbnailOrientationMatchError.disagreement(winners)
        }
        return ThumbnailOrientationMatch(clockwiseQuarterTurns: winner, scoresBySize: allScores)
    }

    static func rotate(_ image: CGImage, clockwiseQuarterTurns: Int) throws -> CGImage {
        let turns = ((clockwiseQuarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swapsAxes = turns % 2 == 1
        let width = swapsAxes ? image.height : image.width
        let height = swapsAxes ? image.width : image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ThumbnailOrientationMatchError.undecodableOriginal
        }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else {
            throw ThumbnailOrientationMatchError.undecodableOriginal
        }
        return result
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary)
    }

    private static func aspectMatches(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        let lhsRatio = Double(lhs.width) / Double(lhs.height)
        let rhsRatio = Double(rhs.width) / Double(rhs.height)
        return abs(log(lhsRatio / rhsRatio)) <= aspectTolerance
    }

    private static func raster(_ image: CGImage, width requestedWidth: Int? = nil,
                               height requestedHeight: Int? = nil) throws -> ComparisonRaster {
        let scale = Double(comparisonLongSide) / Double(max(image.width, image.height))
        let width = requestedWidth ?? max(2, Int((Double(image.width) * scale).rounded()))
        let height = requestedHeight ?? max(2, Int((Double(image.height) * scale).rounded()))
        var bytes = Array(repeating: UInt8(0), count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else {
            throw ThumbnailOrientationMatchError.undecodableOriginal
        }
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ThumbnailOrientationMatchError.undecodableOriginal }
        return ComparisonRaster(width: width, height: height,
                                pixels: bytes.map { Double($0) / 255 })
    }

    private static func score(_ reference: ComparisonRaster,
                              _ candidate: ComparisonRaster) throws -> Double {
        guard reference.width == candidate.width, reference.height == candidate.height,
              reference.pixels.count >= 4 else {
            throw ThumbnailOrientationMatchError.undecodableOriginal
        }
        let luminance = correlationError(reference.pixels, candidate.pixels)
        let referenceEdges = edges(reference)
        let candidateEdges = edges(candidate)
        let structure = correlationError(referenceEdges, candidateEdges)
        return luminance * 0.8 + structure * 0.2
    }

    /// Zero means identical after brightness/contrast normalization; one means fully
    /// anticorrelated. Near-constant images deliberately return an ambiguous score.
    private static func correlationError(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = Double(lhs.count)
        let lhsMean = lhs.reduce(0, +) / count
        let rhsMean = rhs.reduce(0, +) / count
        var covariance = 0.0
        var lhsVariance = 0.0
        var rhsVariance = 0.0
        for index in lhs.indices {
            let a = lhs[index] - lhsMean
            let b = rhs[index] - rhsMean
            covariance += a * b
            lhsVariance += a * a
            rhsVariance += b * b
        }
        guard lhsVariance > 0.000_001, rhsVariance > 0.000_001 else { return 0.5 }
        let correlation = max(-1, min(1, covariance / sqrt(lhsVariance * rhsVariance)))
        return (1 - correlation) / 2
    }

    private static func edges(_ raster: ComparisonRaster) -> [Double] {
        var result = Array(repeating: 0.0, count: raster.pixels.count)
        for y in 1..<raster.height {
            for x in 1..<raster.width {
                let index = y * raster.width + x
                let horizontal = raster.pixels[index] - raster.pixels[index - 1]
                let vertical = raster.pixels[index] - raster.pixels[index - raster.width]
                result[index] = sqrt(horizontal * horizontal + vertical * vertical)
            }
        }
        return result
    }
}
