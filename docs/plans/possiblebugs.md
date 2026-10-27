# Possible bugs

Suspected incorrect behavior moved from [Ideas.md](Ideas.md). These reports need reproduction unless a verification result is stated below.

- **Cached content in older dates and filtered views:** previously warmed content can appear unavailable even when the cache is below its budget. Filtered-page delivery and discovery of subsequently cached pages now have regression coverage and fixes; the separate older-date browsing symptom still needs reproduction.
- **Map restoration and repeated rebuilding:** the former fingerprint-based implementation has been replaced by the unified metadata engine. Offline tests cover unchanged relaunch without a scan, unsupported-source fallback, scan races and cache trimming. The original live symptom needs a short two-launch acceptance check with the current engine; see [unified plan](WIP_DIFF_CACHE_PLAN.md#live-acceptance-short-and-conclusive).
- **Browser leading inset:** an earlier report said images touched the sidebar. The current browser includes a leading inset; verify whether any destination or layout still reproduces the problem.
- **Cache eviction correctness:** verify retention priorities, budget enforcement, and LRU within a retention class. The code audit and targeted LRU test passed; no eviction defect was established. Revisit if there is a concrete reproduction.
