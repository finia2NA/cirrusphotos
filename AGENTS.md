# Project overview

- **Purpose:** A SwiftUI client for Synology Photos hosted on the remote Synology NAS `cirrus`.
- **User-facing purpose:** Browse a very large remote photo library responsively, including when previously cached data is offline or the connection is slow.
- **Product context:** This is an alpha macOS 27+ application. Backward compatibility is not supported before 1.0; work advances through narrow, testable slices.
- **Current scope:** Personal Library with session-only incremental metadata filtering, Favorites, read-only Personal Space albums, a clustered location Map, a shared virtualized photo/video browser and in-window viewer with configurable pixel interpolation, selectable NAS-converted or original video playback, selection, favorite and photo-rotation mutations, manual and automatic thumbnail-only rotation, an Info utility panel, persistent navigation, and bounded cache warming are implemented. Place labels, album writes, Shared Space browsing, general upload, and sharing are not.
- **Core domain concepts:** Synology Photos spaces, photo/video items, timelines, collections, albums, thumbnails, originals, locations, selections, and authenticated DSM sessions.
- **Data contract:** The NAS is authoritative. Metadata and media are delivered cached-first and demanded metadata is normally validated once per run; stale cached content remains useful when validation fails. External changes are not polled during a session.
- **Architecture:** A process-shared repository actor owns authentication, cached-first metadata coordination, persistence, mutations, and media work behind typed domain APIs. SwiftUI provides the shell, an AppKit viewport virtualizes the shared browser, AVFoundation plays repository-backed video ranges, SQLite indexes metadata/LRU state, and compressed media is stored as files in the ignored repository `.cache/` directory.
- **Compatibility policy:** Incompatible preferences or cache schemas are discarded and recreated rather than migrated.
- **Sources of truth:** The Synology Photos service on `cirrus`; Synology's DSM Login Web API documentation; and observed/reverse-engineered Synology Photos endpoints.

## Required project reading

- Before planning or implementing product/code changes, read `docs/PROJECT.md` and `docs/ARCHITECTURE.md`. They are the current product and technical sources of truth; `AGENTS.md` is only the orientation and rule set.
- Plans describe proposed or completed work and are not current-behavior sources unless explicitly stated. Prefer source, `docs/PROJECT.md`, and `docs/ARCHITECTURE.md` when they differ.

# Rules for agents

- Never inspect, dump, search, or print `.env` wholesale, and never expose its values in tool input or output. Use `.env.example` as the only source for discovering which fields exist. Agents may load only those specifically named values from `.env` into an authenticated app, test, or probe at runtime, provided the values remain opaque and are never echoed, logged, summarized, or otherwise revealed.
- Until 1.0, do not add or retain backward-compatibility shims, migrations, deprecated APIs, or tests solely for older app formats. Remove superseded code and documentation. Discard incompatible persisted preferences/cache data and recreate it; retain validation required by current server responses.
- Keep the amount of marketing-sounding, excessive copy in the application and its documentation to a minimum. Focus on clarity in both.
- The Synology Photos API is unofficially documented in https://github.com/zeichensatz/SynologyPhotosAPI, vendored as a git submodule at `docs/SynologyPhotosAPI/`. Read the local copy (for example `docs/SynologyPhotosAPI/API/SYNO.Foto/SYNO.Foto.Browse.Album.list.md`); if that directory is missing or empty (a fresh clone or worktree), run `git submodule update --init docs/SynologyPhotosAPI` first. You may refer to it for ideas and exploration, but do not assume that it is complete, correct, or the best way to do things. If you are unsure about a read-only endpoint, you may perform your own exploration. For any write endpoints, you must confirm with the user before proceeding.
- Tell the user whenever you lack confidence that you can proceed with a clean implementation. Explain the uncertainty and what would resolve it.
- Tell the user when a HAR capture from the Synology Photos web app would help, and identify the interaction or request that should be captured.
- If the goal is unclear or more information is needed, tell the user and ask focused clarifying questions.
- Every keyboard shortcut added to the app must also be exposed as an appropriately named macOS menu-bar command. Treat the menu command as the discoverable command definition and attach its shortcut there rather than implementing a hidden view-only shortcut.
- When being asked to write a plan, include specifics about files, functions, interfaces, etc that need to be created or modified. Include a clear description of the intended behavior and any relevant constraints. Avoid vague or high-level descriptions that do not provide actionable guidance.
  - Assume the plan will be executed by a less capable agent. Include all relevant details, and do not assume the executing agent will have the intuition necessary for an elegant implementation without guidance if it is not trivial.

## Top Level Documentation

Maintain the "Project overview" section in the repository's root `AGENTS.md`.

When user messages or implementation reveal durable information about the project, edit this `AGENTS.md` file and update that section.

Keep it concise. It is an orientation card, not the product or architecture specification. A newly spawned agent should be able to understand:

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

When durable project knowledge is too detailed for the overview, move it rather than expanding `AGENTS.md`:

- use `docs/PROJECT.md` for product/domain concepts and terminology
- use `docs/ARCHITECTURE.md` for architecture, subsystem boundaries, data flow, and sources of truth
- use `docs/decisions/` for significant architectural or library decisions and their rationale

Prefer updating existing documentation over adding duplicate notes. Keep documentation current rather than historical.

Consult these documents when they are relevant to the task.
