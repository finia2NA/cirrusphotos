import Foundation
import SynologyAPI

enum MetadataWorkResource: Sendable, Equatable {
    case timeline(PhotoCollectionDescriptor)
    case page(key: String, collection: PhotoCollectionDescriptor)
    case albumList
    case locationIndex
    case transient(PhotoCollectionDescriptor)
    case mutation
}

struct MetadataWorkToken: Sendable {
    let admissionEpoch: UInt64
    let wholeGeneration: Int
    let metadataGeneration: Int
    let jobID: UUID
    let resource: MetadataWorkResource
    let mutationEpoch: UInt64?
}

struct CachedMetadata<Value: Sendable>: Sendable {
    let value: Value
    let entry: CacheEntry
}

enum MetadataAdmissionError: LocalizedError {
    case resetInProgress
    case superseded

    var errorDescription: String? {
        switch self {
        case .resetInProgress: "The metadata cache is being reset."
        case .superseded: "A newer metadata value replaced this request."
        }
    }
}

extension CachedPhotosRepository {
    func readCachedMetadata<Value: Decodable & Sendable>(
        _ type: Value.Type,
        key: String
    ) async throws -> CachedMetadata<Value>? {
        let epoch = metadata.admissionEpoch
        guard !metadata.resetInProgress else { throw MetadataAdmissionError.resetInProgress }
        guard let entry = try await store.get(key) else {
            guard epoch == metadata.admissionEpoch, !metadata.resetInProgress else {
                throw MetadataAdmissionError.superseded
            }
            return nil
        }
        guard epoch == metadata.admissionEpoch, !metadata.resetInProgress else {
            throw MetadataAdmissionError.superseded
        }
        guard let value = try? JSONDecoder().decode(type, from: entry.data) else { return nil }
        return CachedMetadata(value: value, entry: entry)
    }

    func captureMetadataWorkToken(
        resource: MetadataWorkResource,
        jobID: UUID,
        collection: PhotoCollectionDescriptor? = nil
    ) async throws -> MetadataWorkToken {
        let epoch = metadata.admissionEpoch
        guard !metadata.resetInProgress else { throw MetadataAdmissionError.resetInProgress }
        let wholeGeneration = await store.currentGeneration()
        let metadataGeneration = await store.currentMetadataGeneration()
        guard epoch == metadata.admissionEpoch, !metadata.resetInProgress else {
            throw MetadataAdmissionError.superseded
        }
        return MetadataWorkToken(
            admissionEpoch: epoch,
            wholeGeneration: wholeGeneration,
            metadataGeneration: metadataGeneration,
            jobID: jobID,
            resource: resource,
            mutationEpoch: collection.map { metadata.mutationEpochs[$0, default: 0] }
        )
    }

    func metadataTokenIsCurrent(_ token: MetadataWorkToken) async -> Bool {
        guard !metadata.resetInProgress,
              token.admissionEpoch == metadata.admissionEpoch else { return false }
        if let expectedMutation = token.mutationEpoch {
            let collection: PhotoCollectionDescriptor?
            switch token.resource {
            case .timeline(let value): collection = value
            case .page(_, let value): collection = value
            case .transient(let value): collection = value
            case .albumList, .locationIndex, .mutation: collection = nil
            }
            if let collection,
               metadata.mutationEpochs[collection, default: 0] != expectedMutation { return false }
        }
        let identityIsCurrent: Bool
        switch token.resource {
        case .timeline(let collection):
            identityIsCurrent = metadata.timelineJobs[collection]?.id == token.jobID
        case .page(let key, _):
            identityIsCurrent = metadata.pageJobs[key]?.id == token.jobID
        case .albumList:
            identityIsCurrent = metadata.albumListJob?.id == token.jobID
        case .locationIndex:
            identityIsCurrent = metadata.locationIndexWork?.id == token.jobID
        case .transient, .mutation:
            identityIsCurrent = true
        }
        guard identityIsCurrent else { return false }
        let wholeGeneration = await store.currentGeneration()
        let metadataGeneration = await store.currentMetadataGeneration()
        return wholeGeneration == token.wholeGeneration &&
            metadataGeneration == token.metadataGeneration
    }

    func commitMetadata<Value: Encodable & Sendable>(
        _ value: Value,
        key: String,
        kind: CacheKind,
        validatedRun: String?,
        token: MetadataWorkToken,
        replacing expectation: MetadataRowExpectation
    ) async throws -> MetadataCommitResult {
        guard await metadataTokenIsCurrent(token) else { return .generationChanged }
        let bytes = try JSONEncoder().encode(value)
        let result = try await store.putMetadata(
            key,
            kind: kind,
            data: bytes,
            validatedRun: validatedRun,
            expectedGeneration: token.wholeGeneration,
            expectedMetadataGeneration: token.metadataGeneration,
            replacing: expectation
        )
        guard await metadataTokenIsCurrent(token) else { return .generationChanged }
        return result
    }

    func rowExpectation(for entry: CacheEntry?) -> MetadataRowExpectation {
        entry.map { .revision($0.revision) } ?? .absent
    }
}
