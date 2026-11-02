import SynologyAPI

extension CachedPhotosRepository {
    public func tags(space: PhotoSpace) -> AsyncStream<ResourceEvent<[TagSummary]>> {
        metadataIndex(key: space, space: space, name: "Tags", jobs: \.tagsJob,
            cached: { try await $0.metadataTags($1) },
            fetch: { try await $0.tags(space: space) },
            persist: { try await $0.storeMetadataTags($2, namespace: $1, currentRun: $3, admission: $4) })
    }
}
