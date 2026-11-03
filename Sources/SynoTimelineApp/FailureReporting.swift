import PhotoCache

/// Logs a failure the app shows to the user and returns its message. Unexpected
/// failures appear in Console under `s:local.cirrus.syno-timeline c:unexpected`.
func reportedFailure(_ error: any Error, operation: String) -> String {
    RepositoryError.record(error, operation: operation).localizedDescription
}
