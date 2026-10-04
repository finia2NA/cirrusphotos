# Remaining cleanup

These items from the October 2026 cleanup audit were intentionally not implemented in the current cleanup series.

## 1. Reduce `CachedPhotosRepository` scope

`CachedPhotosRepository` still coordinates authentication, cached-first resource streams, shared request jobs, request promotion, favorite overrides, optimistic cache patching, rollback, and authoritative Favorites refresh. The single actor remains useful for ordering, but the implementation is still a broad subsystem container with repeated job and stream lifecycle patterns.

Before changing it, identify actor-owned boundaries that preserve the current ordering guarantees. The safest first candidates are authentication/session state and Favorites mutation coordination. A shared request helper should be introduced only if timeline, page, thumbnail, and original-image lifecycles can retain their distinct validation and admission policies.

## 2. Decide the lifecycle of completed plan documents

Completed and historical plans now live together under `docs/plans`, with current behavior explicitly delegated to `docs/ARCHITECTURE.md` and `AGENTS.md`. Their contents were retained because some still contain evidence, rationale, and manual verification checklists, but several passages describe superseded UI and implementation states.

Choose whether to delete completed plans after extracting durable decisions, retain them as explicitly dated history, or rewrite selected documents as current checklists. Until then, they must not be treated as descriptions of the running application.

## 3. Simplify navigation persistence

`NavigationRestoration.swift` still uses a versioned document, a tagged anchor enum with one case, dynamic coding keys, and recovery for unknown future anchor kinds. This is more extensibility than the current two destinations and one anchor type require.

If alpha builds do not need preference compatibility, replace it with one concrete payload and discard the complete saved value when its schema version differs. Keep the semantic photo/day/offset anchor itself; only the speculative forward-compatibility layer is in question.
