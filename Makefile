SHELL := /bin/zsh
.DEFAULT_GOAL := start
.PHONY: start release profile debug clean cloc switch-user dmg publish deploy-site print-site-url

start:
	./scripts/run.sh

# Optimized development build; use it when judging performance. The public build is
# scripts/run.sh --distribution.
release:
	./scripts/run.sh --release

# Launches the optimized build under Instruments with a countdown and saves the trace in
# .build/profiles/. Example: make profile PROFILE_SECONDS=20 PROFILE_TEMPLATE="Animation Hitches"
PROFILE_SECONDS ?= 40
PROFILE_TEMPLATE ?= Time Profiler
profile:
	./scripts/run.sh --release --build-only
	@./scripts/profile.sh '$(PROFILE_SECONDS)' '$(PROFILE_TEMPLATE)'

debug:
	./scripts/run.sh --build-only
	pgrep -x Console >/dev/null || open -na Console
	@echo "Console search filter for this app's logs:"
	@echo "  subsystem:io.github.finia2na.cirrusphotos"
	@echo "Narrow to one category by appending, e.g. category:navigation.folders (also: unexpected, failures)."
	./.build/Cirrus\ Photos.app/Contents/MacOS/CirrusPhotos

clean:
	swift package clean
	rm -rf -- ".build/Cirrus Photos.app" .build/distribution

cloc:
	@python3 scripts/cloc_report.py

# Switches the development account: make switch-user TARGET=real|test|none.
# none removes .env so the app signs in itself, with a fresh cache deleted on leaving none.
switch-user:
	@python3 scripts/switch_user.py '$(TARGET)'

# Releases (scripts/release.sh). Overridable for forks, e.g. make deploy-site DEPLOY_HOST=myhost.
# make dmg builds and signs the DMG and its appcast item locally; ALLOW_DIRTY=1 permits an
# unclean tree for testing. make publish tags, creates the GitHub release, adds the item to
# website/appcast.xml, commits it and deploys the site; DRY_RUN=1 prints those steps instead.
DEPLOY_HOST ?= ionos
DEPLOY_PATH ?= /var/www/cirrus-photos
SITE_URL ?= https://cirrusphotos.richardhanss.de
GITHUB_REPO ?= finia2NA/cirrusphotos
release_env = DEPLOY_HOST='$(DEPLOY_HOST)' DEPLOY_PATH='$(DEPLOY_PATH)' SITE_URL='$(SITE_URL)' \
	GITHUB_REPO='$(GITHUB_REPO)' ALLOW_DIRTY='$(ALLOW_DIRTY)' DRY_RUN='$(DRY_RUN)'

dmg:
	@$(release_env) ./scripts/release.sh dmg

publish:
	@$(release_env) ./scripts/release.sh publish

deploy-site:
	@$(release_env) ./scripts/release.sh deploy-site

# Lets scripts/run.sh read the feed URL's default from this file.
print-site-url:
	@echo '$(SITE_URL)'
