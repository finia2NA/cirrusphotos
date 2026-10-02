# Project overview

- **Purpose:** A SwiftUI client for Synology Photos hosted on the remote Synology NAS `cirrus`.
- **User-facing purpose:** Browse a very large remote photo library responsively.
- **Product and engineering context:** The project advances through narrow, testable slices. API access, persistent caching, the timeline navigator, a bounded continuous Personal Space browser with background login status, and an in-window full-size photo viewer are implemented.
- **Core domain concepts:** Synology Photos Personal Space and Shared Space, photo/video items, timelines, albums, thumbnails, and authenticated DSM sessions.
- **Current UI scope:** Personal Library scrolls Personal Space in day-grouped, aspect-preserving rows. A retractable sidebar and native translucent toolbar provide navigation, thumbnail display size, and connection status; the timeline supports arrow-key scrolling and menu/keyboard thumbnail-size adjustment. The compact right-side day navigator appears near the pointer or with keyboard focus. Appearance follows macOS; display size is independent of cached rendition size. Photos, including the still image of Live Photos, expand in the same window with thumbnail-first original loading, arrow navigation, zoom/pan, and filename/date/loading status. Video thumbnails show server duration; location labels and video playback are deferred.
- **Application:** A macOS 27+ SwiftUI executable built with SwiftPM (`bash scripts/run-prototype.sh`). It authenticates to Cirrus, fetches the Personal Space timeline, and uses equal space per distinct populated day. NAS data is assumed static for an app session; live change reconciliation is out of scope.
- **Cache behavior:** Show cached full timeline, exact item page, thumbnail, and original-photo data first, then validate demanded resources once per app run because the NAS may change between runs. SQLite indexes metadata and LRU records; compressed thumbnails and originals are disk files; originals evict before thumbnails. Thumbnail decoding uses a bounded memory cache, while original decoding retains only the displayed image under a separate decode limit. The Library menu can explicitly warm the current rendition for an inclusive populated-day range using low-priority, cancellable work. The development cache is stored in the repository's ignored `.cache/` directory so macOS does not treat it as purgeable. Settings control rendition size and a 200 MB–100 GB disk budget; see `docs/CACHING_PLAN.md` for current limits.
- **Sources of truth:** The Synology Photos service on `cirrus`; Synology's DSM Login Web API documentation; and observed/reverse-engineered Synology Photos endpoints.
- **Major architectural characteristics:** SwiftUI shell with a native AppKit virtualized photo viewport, compact server timeline and slice geometry indexes, section-sized item pages, pure justified-row geometry, and demand-driven thumbnails. One process-shared repository coordinates cached-first requests and replaying authentication status. The viewport retains at most eight pages and hosts only nearby rows; metadata, image, and decode work have bounded concurrency or memory. Each viewer retains at most three metadata pages, eagerly warms adjacent thumbnails, and prefetches adjacent originals only after current-image success; selection generations reject obsolete work.

# Rules for agents

Keep the amount of marketing-sounding, excessive copy in the application and its documentation to a minimum. Focus on clarity in both.

- Tell the user whenever you lack confidence that you can proceed with a clean implementation. Explain the uncertainty and what would resolve it.
- Tell the user when a HAR capture from the Synology Photos web app would help, and identify the interaction or request that should be captured.
- If the goal is unclear or more information is needed, tell the user and ask focused clarifying questions.

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
