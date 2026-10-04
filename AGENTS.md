# Project overview

- **Purpose:** A SwiftUI client for Synology Photos hosted on the remote Synology NAS `cirrus`.
- **User-facing purpose:** Browse a very large remote photo library responsively.
- **Product and engineering context:** The project advances through narrow, testable slices. API access, persistent caching, the timeline navigator, bounded continuous Personal Library and Favorites browsers with background login status, and an in-window full-size photo viewer are implemented.
- **Core domain concepts:** Synology Photos Personal Space and Shared Space, photo/video items, timelines, albums, thumbnails, and authenticated DSM sessions.
- **Current UI scope:** Personal Library and the Favorites collection scroll Personal Space in day-grouped, aspect-preserving rows using the same virtualized browser. The app restores the last native-sidebar destination and each destination's photo/date scroll anchor across launches. A standard macOS split-view sidebar and native translucent toolbar provide navigation, thumbnail display size, and connection status; the timeline supports arrow-key scrolling and menu/keyboard thumbnail-size adjustment. The compact right-side day navigator appears near the pointer or with keyboard focus. Appearance follows macOS; display size is independent of cached rendition size. Photos, including the still image of Live Photos, expand in the same window with collection-specific arrow navigation, thumbnail-first original loading, zoom/pan, capture-local filename/date/loading status, and a favorite toggle exposed in the Library menu with `.`. The timeline follows viewer navigation in the background and the viewer collapses back to the current photo. Favorited items have timeline heart badges. Video thumbnails show server duration; location labels and video playback are deferred.
- **Application:** A macOS 27+ SwiftUI executable built with SwiftPM (`bash scripts/run-prototype.sh`). It authenticates to Cirrus, eagerly fetches the Personal Library and Favorites timelines, and uses equal space per distinct populated day. External NAS changes are not polled during a session. Local favorite mutations optimistically update status and Personal Library badges, then refresh authoritative Favorites ordering after successful writes; write failures roll back status.
- **Cache behavior:** Show cached full timeline, exact item page, thumbnail, and original-photo data first, then validate demanded resources once per app run because the NAS may change between runs. SQLite indexes metadata and LRU records; compressed thumbnails and originals are disk files. Changing the configured thumbnail rendition preserves other cached sizes: the nearest compatible cached rendition remains visible while browsing, viewer navigation, or the manual range downloader obtains the exact selected size. Retention is dynamically prioritized through one global policy: exact configured thumbnails, smaller fallbacks while exact bytes are absent, then optional larger/redundant renditions; metadata remains above image data and originals remain above optional variants. An opt-in viewer setting loads cached `xl` previews alongside originals when the library uses a smaller rendition. Configured small/medium thumbnails and cached viewer assets remain immediate, while network-backed `xl` and original requests wait 100 ms for a stable selection to avoid transfers during key repeat. Thumbnail decoding uses a bounded memory cache, while original decoding retains only the displayed image under a separate decode limit. The Library menu can explicitly warm the current rendition for an inclusive populated-day range using low-priority, cancellable work and run-local size, speed, and remaining-time estimates; exact indexed files are reused without network revalidation by this manual operation. The development cache is stored in the repository's ignored `.cache/` directory so macOS does not treat it as purgeable. Settings control rendition size, large viewer previews, and a 200 MB–100 GB disk budget; see `docs/CACHING_PLAN.md` for current limits.
- **Cache schema policy:** The account-scoped SQLite index has an explicit version. Incompatible or unreadable index data and its image files are discarded and fetched again from the NAS; cache files from earlier macOS locations are not migrated.
- **Sources of truth:** The Synology Photos service on `cirrus`; Synology's DSM Login Web API documentation; and observed/reverse-engineered Synology Photos endpoints.
- **Major architectural characteristics:** SwiftUI shell with a native split-view sidebar and AppKit virtualized photo viewport, collection-aware server timelines and slice geometry indexes, section-sized item pages, pure justified-row geometry, and demand-driven thumbnails. One process-shared repository coordinates cached-first requests, collection-isolated metadata caches, optimistic favorite status, authoritative post-mutation Favorites refreshes, shared image caches, and replaying authentication status. A typed scroll-intent coordinator arbitrates restoration, viewer follow, day jumps, and user scrolling. The viewport retains at most eight pages and hosts only nearby rows; metadata, image, and decode work have bounded concurrency or memory. Each collection-specific viewer is one actor with owned metadata-window and image-lifecycle values; it retains at most three metadata pages, eagerly warms adjacent configured or `xl` preview thumbnails, and prefetches adjacent originals only after current-image success. A Favorites viewer keeps a session-local mutation ledger and reconstructs evicted pages so its opening playlist remains stable; selection generations and mutation epochs reject obsolete work.

# Rules for agents

Keep the amount of marketing-sounding, excessive copy in the application and its documentation to a minimum. Focus on clarity in both.

The synology photos API is unoficially documented in
https://github.com/zeichensatz/SynologyPhotosAPI. You may refer to this for ideas and exploration, but do not assume that it is complete, correct, or the best way to do things. If you are unsure, about a read-only endpoint, you may perform your own exploration. For any write endpoints, you must confirm with the user before proceeding.

- Tell the user whenever you lack confidence that you can proceed with a clean implementation. Explain the uncertainty and what would resolve it.
- Tell the user when a HAR capture from the Synology Photos web app would help, and identify the interaction or request that should be captured.
- If the goal is unclear or more information is needed, tell the user and ask focused clarifying questions.
- Every keyboard shortcut added to the app must also be exposed as an appropriately named macOS menu-bar command. Treat the menu command as the discoverable command definition and attach its shortcut there rather than implementing a hidden view-only shortcut.

## Top Level Documentation

Maintain the "Project overview" section in the repository's root `AGENTS.md`.

When user messages or implementation reveal durable information about the project, edit this `AGENTS.md` file and update that section.

Keep it concise. A newly spawned agent should be able to understand:

- The purpose of the application
- Its main user-facing purpose
- The target audience
- The product engineering context, including UX and architectural priorities
- Core domain concepts
- Important sources of truth, when applicable
- The most important architectural characteristics

Only document what is true now. Do not speculate, especially about purpose, target audience, maturity, or operating context when they are not clear from user messages or implementation.

EXAMPLE for documentation only — NOT THIS PROJECT:
- **Purpose:** Dashboard for monitoring the status of a distributed system.
- **User-facing purpose:** Gives the user a fast overview of service health, recent failures, and system activity.
- **Target audience:** Primarily the author; not intended for public use.
- **Product and engineering context:** Personal-use application with low expected scale. Reliability and maintainability matter, but enterprise-scale infrastructure and extensive onboarding are unnecessary. UX should favor efficiency and clarity over polish. Architectural priorities are simplicity, maintainability, and ease of change.
- **Core domain concepts:** Services, nodes, health checks, incidents, and recent activity.
- **Sources of truth:** Monitoring data collected from the distributed system. The dashboard only presents and aggregates that data.
- **Major architectural characteristics:** Simple and local-first where practical, with clear separation between data collection, state/query logic, and the UI.

## Detailed project knowledge

When durable project knowledge is too detailed for the overview:

- use `docs/PROJECT.md` for product/domain concepts and terminology
- use `docs/ARCHITECTURE.md` for architecture, subsystem boundaries, data flow, and sources of truth
- use `docs/decisions/` for significant architectural or library decisions and their rationale

Prefer updating existing documentation over adding duplicate notes. Keep documentation current rather than historical.

Consult these documents when they are relevant to the task.
