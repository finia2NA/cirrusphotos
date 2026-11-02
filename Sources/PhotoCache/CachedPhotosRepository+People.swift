import SynologyAPI

extension CachedPhotosRepository {
    public func people(space: PhotoSpace = .personal) -> AsyncStream<ResourceEvent<[PersonSummary]>> {
        metadataIndex(key: space, space: space, name: "People", jobs: \.peopleJob,
            cached: { try await $0.metadataPeople($1) },
            fetch: { try await $0.people(space: space) },
            persist: { try await $0.storeMetadataPeople($2, namespace: $1, currentRun: $3, admission: $4) })
    }
}
