# Project overview

- **Purpose:** A SwiftUI client (Cirrus Photos) for Synology Photos hosted on the remote Synology NAS `cirrus`.
- **User-facing purpose:** Browse a very large remote photo library responsively, including when cached data is offline or the connection is slow.
- **Product context:** Alpha macOS 27+ application; no backward compatibility before 1.0. Narrow, testable slices; bound investigations and use conservative fallbacks rather than probing every NAS edge case. Priorities: cached whenever possible, performant, and as simple as the complicated domain allows. One repository-owned metadata engine serves all collections.
- **Scope:** The feature inventory and pending work are in `docs/PROJECT.md`.
- **Core domain concepts:** Synology Photos spaces (Personal, Shared), photo/video items, timelines, collections, albums, thumbnails, originals, locations, selections, and authenticated DSM sessions. Typed content scopes (Personal, Shared, album authority) have isolated metadata, media and mutation authority. Album sharing is separate from Shared Space.
- **Data contract:** The NAS is authoritative. Metadata and media are delivered cached-first and metadata is normally validated once per run (Diff v7 feeds prove cached pages unchanged, or a background sync reads them); stale cached content stays useful when validation fails. Nothing polls for external changes; manual Refresh (⌘R) re-validates in place.
- **Architecture:** A process-shared repository actor owns authentication, cached-first metadata coordination, filter indexing, persistence, mutations and media work behind typed domain APIs. SwiftUI provides the shell, an AppKit viewport virtualizes the shared browser, GRDB records over SQLite hold metadata and compressed media is stored as files: development builds in the checkout's ignored `.cache/`, distribution builds (`scripts/run.sh --distribution`) in `~/Library/Application Support/de.richardhanss.cirrus-photos/` (#84 moves it).
- **Credentials:** without `.env`, the app signs in itself (server, user, password, six-digit code; Keychain, trusted-device token, switchable accounts). A present `.env` (`NAS_URL`, `USER`, `PW`, optional TOTP secret `OTP`; see `.env.example`) takes precedence in development builds; distribution builds ignore it.
- **Diagnostics:** Unified logging under subsystem `de.richardhanss.cirrus-photos` (the bundle ID); the bundle's `OSLogPreferences` keeps info and debug on disk, so `log show --last 15m --info --debug --predicate 'subsystem == "de.richardhanss.cirrus-photos"'` shows what preceded a crash. Crash reports are in `~/Library/Logs/DiagnosticReports/CirrusPhotos-*.ips`.
- **Test environment:** The disposable `phototest` account (`.env.test`) is for risky operations.
- **Sources of truth:** The Synology Photos service on `cirrus`; Synology's DSM Login Web API documentation; observed/reverse-engineered Photos endpoints (`docs/SYNOLOGY_PHOTOS_API.md`).

## Required project reading

Before planning or implementing product/code changes, read `docs/PROJECT.md` (user-visible behavior) and `docs/ARCHITECTURE.md` (structure and invariants). They are the current sources of truth; this file is only orientation and rules. Prefer source, then those two documents, over plans and issues.

# Rules for agents

- Only use computer use to test the app when the user explicitly asks for it.
- Never inspect, dump, search, or print `.env`, `.env.test`, or `.env.real` wholesale, and never expose their values in tool input or output. Use `.env.example` as the only source for discovering which fields exist. Agents may load only specifically named values into an authenticated app, test, or probe at runtime, provided the values remain opaque and are never echoed, logged, summarized, or revealed.
- For risky operations, use the disposable `phototest` account with its own cache: quit the app, run `make switch-user TARGET=test`, and afterwards `make switch-user TARGET=real`, even if testing fails or is interrupted. Each target parks the other's `.env` and cache (`.env.real`/`.env.test`, `.cache.real`/`.cache.test`); `TARGET=none` removes `.env` so the app signs in itself, with a fresh cache deleted when leaving none. Never move or delete these files by hand. Live write tests against a non-test account need user permission.
- Until 1.0, add or retain no backward-compatibility shims, migrations, deprecated APIs, or tests for older formats. Remove superseded code and documentation. Discard incompatible persisted preferences and cache data and recreate it; keep validation required by current server responses.
- Keep tests relevant: remove a test when its contract no longer applies, update it when the requirement still does, never weaken one to pass, and fix failures that reveal regressions. Test when a feature is done (small changes) or during development (large ones); UI changes without suitable tests need no new tests.
- Keep marketing-style or excessive copy out of the application and the documentation. Focus on clarity.
- The Synology Photos API is unofficially documented in https://github.com/zeichensatz/SynologyPhotosAPI, vendored as a submodule at `docs/SynologyPhotosAPI/` (run `git submodule update --init docs/SynologyPhotosAPI` if empty). It may be incomplete or wrong; explore uncertain endpoints with the disposable test account.
- Communication: tell the user when you lack confidence in a clean implementation (and what would resolve it), when a HAR capture of the Synology Photos web app would help (name the interaction), and ask focused questions when the goal is unclear.
- Every keyboard shortcut must also be exposed as an appropriately named macOS menu-bar command; attach the shortcut to the menu command rather than a hidden view-only shortcut.
- Plans name the files, functions and interfaces to create or modify, the intended behavior and constraints. Assume a less capable agent executes them; avoid vague or high-level descriptions.
- Codex-specific (ignore if the harness used is not Codex):
  - When you are asked to spawn an agent, this means subagent. Do not create a new chat and talk to the agent there.
- Kilo-specific (Ignore if the harness used is not Kilo):
  - GPT 5.6 Sol refers to the model through the OpenAI Codex API. Deepseek refers to Deepseek V4.1 Flash, provided by Deepseek through their API. Use these APIs when spawning subagents. When not otherwise specified, use Sol at medium reasoning and Deepseek at high reasoning.
  - For Kilo subagents, messages from the main agent take priority over conflicting details in the original delegated task. Treat them as current task corrections and coordination, while still following system instructions and direct user requirements.

## Documentation

Keep the "Project overview" current when durable facts change; it is an orientation card, not a specification. Put detail where it belongs and update existing text instead of adding notes:

- `docs/PROJECT.md`: user-visible behavior and scope.
- `docs/ARCHITECTURE.md`: structure, invariants, data flow.
- `docs/SYNOLOGY_PHOTOS_API.md`: request shapes and server facts; `docs/capturefindings/`: how they were established; `docs/decisions/`: significant decisions.
- Document only what is true now; no per-feature history.
- **Size budget:** `AGENTS.md` about 1,000 words, `docs/ARCHITECTURE.md` about 6,000 (sections short enough for one screen, no paragraph over about 150 words), `docs/PROJECT.md` about 4,600. When an edit would exceed a budget, condense existing text first.
