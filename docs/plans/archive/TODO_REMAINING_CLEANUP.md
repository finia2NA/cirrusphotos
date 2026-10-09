# Remaining cleanup

This item from the October 2026 cleanup audit remains open.

## 1. Reduce `CachedPhotosRepository` scope

`CachedPhotosRepository` still coordinates authentication, cached-first resource streams, shared request jobs, request promotion, favorite overrides, optimistic cache patching, rollback, and authoritative Favorites refresh. The single actor remains useful for ordering, but the implementation is still a broad subsystem container with repeated job and stream lifecycle patterns.

Before changing it, identify actor-owned boundaries that preserve the current ordering guarantees. The safest first candidates are authentication/session state and Favorites mutation coordination. A shared request helper should be introduced only if timeline, page, thumbnail, and original-image lifecycles can retain their distinct validation and admission policies.
