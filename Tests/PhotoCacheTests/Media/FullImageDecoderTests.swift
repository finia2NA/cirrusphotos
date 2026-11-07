import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoCache

final class FullImageDecoderTests: XCTestCase {
    private func encodedImage() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
            bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testOriginalResolutionAndOrientationArePreserved() async throws {
        let bitmap = try await FullImageDecoder().decode(encodedImage())
        XCTAssertEqual(bitmap.image.width, 8)
        XCTAssertEqual(bitmap.image.height, 12)
    }

    func testDisplayQuarterTurnAppliesAfterOriginalEXIFTransform() async throws {
        let bitmap = try await FullImageDecoder().decode(encodedImage())
        let clockwise = try bitmap.rotatedForDisplay(quarterTurns: 1)
        XCTAssertEqual(clockwise.image.width, 12)
        XCTAssertEqual(clockwise.image.height, 8)
        let counterClockwise = try bitmap.rotatedForDisplay(quarterTurns: -1)
        XCTAssertEqual(counterClockwise.image.width, 12)
        XCTAssertEqual(counterClockwise.image.height, 8)
        XCTAssertTrue(try bitmap.rotatedForDisplay(quarterTurns: 4) === bitmap)
    }

    func testOversizedImageFailsInsteadOfSilentlyDownsampling() async throws {
        do {
            _ = try await FullImageDecoder(maximumBytes: 16).decode(encodedImage())
            XCTFail("Should reject an image larger than the decode budget")
        } catch FullImageDecodeError.tooLarge { }
    }

    func testInvalidImageFailsWithoutHangingTheNextDecode() async throws {
        let decoder = FullImageDecoder()
        do {
            _ = try await decoder.decode(Data("not an image".utf8))
            XCTFail("Should reject invalid image bytes")
        } catch FullImageDecodeError.unsupported { }
        let bitmap = try await decoder.decode(encodedImage())
        XCTAssertEqual(bitmap.image.width, 8)
    }
}
