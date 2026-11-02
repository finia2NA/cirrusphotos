import SynologyAPI

extension CachedPhotosRepository {
    public func subjects(space: PhotoSpace) -> AsyncStream<ResourceEvent<[SubjectSummary]>> {
        metadataIndex(key: space, space: space, name: "Subjects", jobs: \.subjectsJob,
            cached: { try await $0.metadataSubjects($1) },
            fetch: { try await $0.subjects(space: space) },
            persist: { try await $0.storeMetadataSubjects($2, namespace: $1, currentRun: $3, admission: $4) })
    }
}
