---
name: ship-release
description: Merge the current branch into main, main into prod, and publish a new Cirrus Photos release (tests, signed DMG, GitHub release, Sparkle appcast, website deploy via `make publish`). Use whenever the user asks to ship, release, publish, deploy, cut a release, push to prod, update the prod app, or "merge and deploy", even if they don't name main or prod.
---

# Ship a release: current branch -> main -> prod -> published app

End state: the work is on `main`, `main` and `prod` point at the same commit (the release commit plus the appcast commit), tag `v<version>` and a GitHub pre-release exist, `website/` is deployed, and installed apps can update through Sparkle.

Publishing is public and hard to undo (a pushed tag, a GitHub release, an rsync with `--delete` to the live site), so the order below is built to fail early and locally: every check and the test/build run happen before anything is pushed, and `main`/`prod` are pushed only after the publish succeeds.

How the repo works (verified, not assumed):
- `prod` is the "last released" pointer. After a release `main == prod == origin/main == origin/prod`; the history is linear (feature commits, `Release <v>`, `Publish Cirrus Photos <v> in the appcast`). Merges therefore fast-forward; if one doesn't, something unexpected happened, so stop and tell the user.
- `scripts/release.sh publish` builds from whatever is checked out and rsyncs the local `website/` to the server, so it must run on the final merged tree (that is why the merges come first).
- Every version needs a new `MARKETING_VERSION`: the tag is `v<MARKETING_VERSION>` and the script refuses an existing tag, so reusing the version after a release always fails. `BUILD_NUMBER` must also rise (the updater compares it).

## 1. Preflight (changes nothing)

Run these and stop on the first failure, saying what is missing:

1. `git status --porcelain` is empty. If not, ask: uncommitted work must not be swept into a release, and the script refuses an unclean tree.
2. `git branch --show-current` (remember it as the original branch); `git fetch origin --tags`.
3. `main` and `prod` exist and are not checked out in another worktree (`git worktree list`; the checkouts under `.claude/worktrees`, `.codex` and `~/.local/share/kilo` are common). If checkout would fail for that reason, stop and tell the user which worktree holds it.
4. `git rev-list --left-right --count origin/main...main` and the same for `prod`: neither local branch may be ahead of or diverged from origin in a way you did not expect. Behind is fine (fast-forward them).
5. Tooling for the release, checked now so a missing piece does not strand a half-done release: `gh auth status`; `ssh -o BatchMode=yes -o ConnectTimeout=5 ionos true`; `ls secrets/sparkle_ed25519_private.key` in the main checkout (existence only, never print or open it); `security find-identity -v -p codesigning | grep "Cirrus Photos"`.
6. Release metadata on the branch being shipped (read `scripts/version.env`, `CHANGELOG.md`, and `website/appcast.xml`'s highest `<sparkle:version>`; the appcast lives on main/prod, so compare against `origin/prod:website/appcast.xml`):
   - `MARKETING_VERSION` differs from every existing tag (`git tag -l`) and has a `## <version>` section in `CHANGELOG.md`;
   - `BUILD_NUMBER` is higher than the highest published build.

   If either is missing, propose the change and get a yes before committing: the next patch version unless the user says otherwise, `BUILD_NUMBER + 1`, and a changelog section drafted from `git log --oneline origin/prod..HEAD`, in the existing style (short user-visible bullets, no marketing copy, no internal refactors). Commit it on the branch being shipped as "Release <version>".
7. Tell the user the plan in a few lines (branch -> main -> prod, version/build, tag, what is deployed) and get an explicit yes. This is the point of no return; a bare "ship it" in the same message that named the version counts.

## 2. Merge locally (nothing pushed yet)

1. If the original branch is not `main`: `git checkout main && git merge --ff-only origin/main && git merge <branch>`. Prefer fast-forward; a merge commit is fine if main moved. Trivial conflicts only; otherwise stop, `git merge --abort`, and show the user.
2. `git checkout prod && git merge --ff-only origin/prod && git merge main`. This should fast-forward.

## 3. Publish from prod

```sh
make publish
```

The script runs `swift test` first, builds and verifies the distribution bundle, makes the DMG, signs the update, and only then tags `v<version>`, pushes the tag, creates the GitHub pre-release, adds the appcast item, commits it, and rsyncs the site. The whole run takes several minutes: run it in the background, wait for it to exit, and read the output; do not poll.

Skip `DRY_RUN=1`: the dry run still does the full test and build, so it doubles the wait and checks little that preflight did not.

If it fails before "Tagging and creating the GitHub release" (tests, build, verification), nothing public happened. Report the error and leave the local merges in place (nothing was pushed) or reset them if the user wants. If it fails after the tag was pushed, stop: report exactly which steps completed and ask the user how to proceed; do not re-run `make publish` (it refuses an existing tag) and do not delete tags.

## 4. Push and level main

1. `git push origin prod`.
2. `git checkout main && git merge --ff-only prod && git push origin main`, so main has the release and appcast commits and the next release's checks see them.
3. `git checkout <original branch>`. If it is not main, mention it is now behind main (the user can `git merge main` when they next work on it).

## 5. Report

Give: version and build number, tag, the release URL (`gh release view v<version> --repo finia2NA/cirrusphotos --json url -q .url`), confirmation that `main` and `prod` are level with origin (`git rev-parse --short main prod origin/main origin/prod`), and what branch is checked out. Optionally confirm the live feed: `curl -s https://cirrusphotos.richardhanss.de/appcast.xml | grep -c "<sparkle:version>"`. Say plainly anything skipped or unverified; the app's actual self-update was not exercised.

## Rules

- Never launch, quit, or restart the Cirrus Photos app; building is fine.
- Never force-push, delete branches or worktrees, or move or delete tags.
- Never print or open `.env*` files or the contents of `secrets/`.
- Commit messages carry no attribution lines.
