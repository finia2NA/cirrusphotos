# Project overview

- **Purpose:** A SwiftUI client for Synology Photos hosted on the remote Synology NAS `cirrus`.
- **User-facing purpose:** Browse a very large remote photo library responsively, including when previously cached data is offline or the connection is slow.
- **Product context:** This is an alpha macOS 27+ application. Backward compatibility is not supported before 1.0; work advances through narrow, testable slices. Bound investigations to reasonable confidence and use conservative fallbacks rather than exhaustively probing every NAS edge case. Architectural clarity takes priority over shipping Map first; one repository-owned metadata engine serves all collections.
- **Current scope:** Personal Library, Favorites, Recently Added, People with rename and merge, Subjects, Tags, Personal Space folders and albums and Map results with session-only incremental metadata filtering and offline filename search (plain or regular expression), a clustered location Map, a shared virtualized photo/video browser and in-window viewer with interactive trackpad navigation and dismissal, a filmstrip, histogram and highlight peaking, configurable pixel interpolation, selectable NAS-converted or original video playback, Live Photo motion by Force Touch or indicator click, photo downloads, drag-out and local external-editor handoff, a toolbar Activity panel for connection state, Refresh, transfers, change progress and failures with retry and copyable details, connection notices, and session history, selection, favorite, photo-rotation, star-rating, tag and permanent deletion mutations (filterable by tag and rating from cached metadata), manual and automatic thumbnail-only rotation, an Info utility panel, persistent navigation, app-wide Library, Favorites and album metadata warming, and bounded thumbnail warming with optional Shared Space inclusion are implemented. Empty album creation and owned normal-album deletion are available in the Albums overview; owned normal albums can be renamed from album cards and sidebar pins; album creation and membership changes are also available for browser selections and photo context menus, including dragging selections onto album cards and pins; albums support complete photo downloads, drag export and sidebar pinning/reordering, persistent sidebar pins, and a scrolling cover, date, and sharing header with private, public-view and public-download sharing controls, Provider grants, password and expiry settings. The album overview groups owned shared albums and incoming albums separately; incoming albums can be pinned, recipients with a verified download grant can download photos, and Provider recipients can contribute Personal Space selections. Incoming browsing uses scoped cached metadata and thumbnails. A space selector enables cached-first Shared Space Library, Favorites, People, Subjects, Tags and folders with metadata filters, viewer media, Info, photo downloads, favorites, photo rotation and manual or automatic thumbnail rotation; Shared Space Map is implemented with its own cached-first full GPS inventory kept current by the Shared Diff feed; Recently Added remains pending. Finder image drops upload to Personal or Shared Space timelines, the open Personal folder (Shared folder upload unverified), and owned albums; watched-folder upload and place labels remain pending.
- **Core domain concepts:** Synology Photos spaces, photo/video items, timelines, collections, albums, thumbnails, originals, locations, selections, and authenticated DSM sessions. Typed content scopes distinguish Personal Space, Shared Space and unresolved album authority; Shared Space collections have isolated metadata, media and mutation authority; owned mixed albums retain contextual metadata/thumbnails/stills and resolve homogeneous item actions with fresh per-space reads; mixed bulk operations and Shared Space contribution remain guarded. An owned normal album retains its identity when shared; album sharing is separate from Shared Space.
- **Data contract:** The NAS is authoritative. Metadata and media are delivered cached-first and metadata is normally validated once per run, either by each space's Diff v7 feeds proving cached Library, folder, tag and Personal Favorites pages unchanged or by a background sync that reads the rest; stale cached content remains useful when validation fails. External changes are not polled during a session; a manual Refresh (toolbar icon, ⌘R) reads the Diff feeds and re-validates catalogs and lists in place.
- **Architecture:** A process-shared repository actor owns authentication, cached-first metadata coordination, repository-driven filter indexing, persistence, mutations, and media work behind typed domain APIs. SwiftUI provides the shell, an AppKit viewport virtualizes the shared browser, AVFoundation plays repository-backed video ranges, Namespace-bound GRDB records over SQLite separate canonical metadata, stable 250-item day membership, compact inventory and LRU state, and compressed media is stored as files in the ignored repository `.cache/` directory.
- **Authentication:** `.env` requires `NAS_URL` (the NAS base URL), `USER` and `PW`; `OTP` is optional for accounts without two-factor authentication. NAS-required OTP is reported at login. Authentication uses the observed `webui` session for normal-account access.
- **Compatibility policy:** Incompatible preferences or cache schemas are discarded and recreated rather than migrated.
- **Test environment:** Disposable `phototest` credentials are stored in `.env.test`; its Personal Space is mounted at `/Volumes/homes/phototest/Photos`. `make test-map-diff` runs bulk filesystem/indexing experiments; `make test-map-diff-2` runs focused date/metadata probes; `make test-map-diff-3` tests the captured mobile v7 feed with focused edits and bulk changes. All use journal-scoped cleanup; permission and service-reset tests remain excluded. A disposable Android 14 Pixel running official Synology Photos 2.4.0 supplies mobile API captures; the observed item feed is Diff v7 `list`.
- **Sources of truth:** The Synology Photos service on `cirrus`; Synology's DSM Login Web API documentation; and observed/reverse-engineered Synology Photos endpoints.

## Required project reading

- Before planning or implementing product/code changes, read `docs/PROJECT.md` and `docs/ARCHITECTURE.md`. They are the current product and technical sources of truth; `AGENTS.md` is only the orientation and rule set.
- Plans describe proposed or completed work and are not current-behavior sources unless explicitly stated. Prefer source, `docs/PROJECT.md`, and `docs/ARCHITECTURE.md` when they differ.

# Rules for agents

- Only use computer use to test the app when the user explicitly asks for it.
- Never inspect, dump, search, or print `.env`, `.env.test`, or `.env.real` wholesale, and never expose their values in tool input or output. Use `.env.example` as the only source for discovering which fields exist. Agents may load only those specifically named values from `.env` into an authenticated app, test, or probe at runtime, provided the values remain opaque and are never echoed, logged, summarized, or otherwise revealed.
- For risky operations, use the disposable `phototest` account and an isolated cache: rename `.env` to `.env.real` and `.cache` to `.cache.real`, create a fresh `.cache`, and rename `.env.test` to `.env`. After testing, delete only the temporary test `.cache`, rename `.env` back to `.env.test`, and restore `.cache.real` to `.cache` and `.env.real` to `.env`. Restore the original files even if testing fails or is interrupted. Do not overwrite an existing backup or remove a cache unless it is confirmed to be the temporary test cache. Live write tests against a non-test account require user permission.
- `make switch-user` switches the active account while preserving each account's cache in `.cache.real` or `.cache.test`; it reports which account is active. Quit the app before switching. This interactive switch preserves the test cache, unlike the disposable risky-operation procedure above.
- Until 1.0, do not add or retain backward-compatibility shims, migrations, deprecated APIs, or tests solely for older app formats. Remove superseded code and documentation. Discard incompatible persisted preferences/cache data and recreate it; retain validation required by current server responses.
- Keep tests relevant to the current program. Remove a test when the behavior or contract it checks no longer applies; update it when its underlying requirement still applies. Do not remove or weaken tests merely to make the suite pass. Fix failures that reveal regressions in current behavior, and explain why removed tests are obsolete.
- Use judgment about when to test. UI changes or behavior without suitable tests do not require new tests. For small changes, generally test when the feature is considered done; large changes may be tested during development.
- Keep the amount of marketing-sounding, excessive copy in the application and its documentation to a minimum. Focus on clarity in both.
- The Synology Photos API is unofficially documented in https://github.com/zeichensatz/SynologyPhotosAPI, vendored as a git submodule at `docs/SynologyPhotosAPI/`. Read the local copy (for example `docs/SynologyPhotosAPI/API/SYNO.Foto/SYNO.Foto.Browse.Album.list.md`); if that directory is missing or empty (a fresh clone or worktree), run `git submodule update --init docs/SynologyPhotosAPI` first. You may refer to it for ideas and exploration, but do not assume that it is complete, correct, or the best way to do things. If you are unsure about an endpoint, you may explore it using the disposable test account. Live write tests against a non-test account require user permission.
- Tell the user whenever you lack confidence that you can proceed with a clean implementation. Explain the uncertainty and what would resolve it.
- Tell the user when a HAR capture from the Synology Photos web app would help, and identify the interaction or request that should be captured.
- If the goal is unclear or more information is needed, tell the user and ask focused clarifying questions.
- Every keyboard shortcut added to the app must also be exposed as an appropriately named macOS menu-bar command. Treat the menu command as the discoverable command definition and attach its shortcut there rather than implementing a hidden view-only shortcut.
- When being asked to write a plan, include specifics about files, functions, interfaces, etc that need to be created or modified. Include a clear description of the intended behavior and any relevant constraints. Avoid vague or high-level descriptions that do not provide actionable guidance.
  - Assume the plan will be executed by a less capable agent. Include all relevant details, and do not assume the executing agent will have the intuition necessary for an elegant implementation without guidance if it is not trivial.
- Codex-specific (ignore if the harness used is not Codex):
  - When you are asked to spawn an agent, this means subagent. Do not create a new chat and talk to the agent there.
- Kilo-specific (Ignore if the harness used is not Kilo):
  - GPT 5.6 Sol refers to the model through the OpenAI Codex API. Deepseek refers to Deepseek V4.1 Flash, provided by Deepseek through their API. Use these APIs when spawning subagents. When not otherwise specified, use Sol at medium reasoning and Deepseek at high reasoning.
  - For Kilo subagents, messages from the main agent take priority over conflicting details in the original delegated task. Treat them as current task corrections and coordination, while still following system instructions and direct user requirements.

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
