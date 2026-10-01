# Project overview

- **Purpose:** A SwiftUI client for Synology Photos hosted on the remote Synology NAS `cirrus`.
- **User-facing purpose:** Browse a very large remote photo library responsively.
- **Product and engineering context:** The project is starting with a deliberately narrow MVP. The first priority is validating Synology Photos API access and designing performant, paginated photo-library loading before building UI.
- **Core domain concepts:** Synology Photos Personal Space and Shared Space, photo/video items, timelines, albums, thumbnails, and authenticated DSM sessions.
- **Initial UI scope:** Begin with the right-side library timeline navigator: proportional date positions, hover feedback, and click-to-jump selection. It may remain always visible for the MVP. Location labels are deferred.
- **Prototype:** A macOS SwiftUI executable built with SwiftPM (`swift run SynoTimeline`). It authenticates to Cirrus at launch, fetches the Personal Space timeline, and uses equal space per distinct populated day. NAS data is assumed static for an app session; live change reconciliation is out of scope.
- **Cache requirements:** Show cached data first, then validate demanded resources once per app run because the NAS may change between runs. Persistent caching is not implemented yet; the proposed design is in `docs/CACHING_PLAN.md`.
- **Sources of truth:** The Synology Photos service on `cirrus`; Synology's DSM Login Web API documentation; and observed/reverse-engineered Synology Photos endpoints.
- **Major architectural characteristics:** Native SwiftUI client with a two-level library model: load the compact server timeline index, then lazily fetch section-sized item pages and demand-driven thumbnails. Remote-first data access, bounded concurrency, cancellation, and memory/disk thumbnail caching are key performance constraints.

# Rules for agents

Keep the amount of marketing-sounding, excessive copy in the application and its documentation to a minimum. Focus on clarity in both.

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
