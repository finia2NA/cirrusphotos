SHELL := /bin/zsh
.DEFAULT_GOAL := start
.PHONY: start release profile debug clean cloc switch-user

start:
	./scripts/run.sh

# Optimized build; use it when judging performance.
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
	@echo "  subsystem:de.richardhanss.cirrus-photos"
	@echo "Narrow to one category by appending, e.g. category:navigation.folders (also: unexpected, failures)."
	./.build/Cirrus\ Photos.app/Contents/MacOS/CirrusPhotos

clean:
	swift package clean
	rm -rf -- ".build/Cirrus Photos.app"

cloc:
	@python3 scripts/cloc_report.py

# Switches the development account: make switch-user TARGET=real|test|none.
# none removes .env so the app signs in itself, with a fresh cache deleted on leaving none.
switch-user:
	@python3 scripts/switch_user.py '$(TARGET)'
