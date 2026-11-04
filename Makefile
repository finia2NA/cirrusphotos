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
	@echo "  subsystem:local.cirrus.syno-timeline"
	@echo "Narrow to one category by appending, e.g. category:navigation.folders (also: unexpected, failures)."
	./.build/Cirrus\ Photos.app/Contents/MacOS/SynoTimeline

clean:
	swift package clean
	rm -rf -- ".build/Cirrus Photos.app"

cloc:
	@python3 scripts/cloc_report.py

switch-user:
	@python3 scripts/switch_user.py

# Temporary filesystem-driven Map/Diff evidence runner (phototest only).
PYTHON ?= python3
MAP_DIFF_PYTHON := .venv/bin/python
.PHONY: map-diff-env test-map-diff test-map-diff-script

$(MAP_DIFF_PYTHON):
	$(PYTHON) -m venv .venv

.venv/.map-diff-dependencies: scripts/requirements-map-diff.txt $(MAP_DIFF_PYTHON)
	$(MAP_DIFF_PYTHON) -m pip install -r scripts/requirements-map-diff.txt
	$(MAP_DIFF_PYTHON) -m pip check
	touch $@

map-diff-env: .venv/.map-diff-dependencies
	$(MAP_DIFF_PYTHON) scripts/test_map_diff.py --check-environment

test-map-diff: map-diff-env
	$(MAP_DIFF_PYTHON) -u scripts/test_map_diff.py $(MAP_DIFF_ARGS)

test-map-diff-script: map-diff-env
	$(MAP_DIFF_PYTHON) -m unittest discover -s scripts -p 'test_map_diff_runner.py' -v

# Second, small historical/current-date experiment. Does not run bulk stages.
.PHONY: test-map-diff-2 test-map-diff-2-script

test-map-diff-2: map-diff-env
	$(MAP_DIFF_PYTHON) -u scripts/test_map_diff_focused.py $(MAP_DIFF_2_ARGS)

test-map-diff-2-script: map-diff-env
	$(MAP_DIFF_PYTHON) -m unittest discover -s scripts -p 'test_map_diff_focused_runner.py' -v

# Third experiment: captured Android Diff v7 list, focused edits + 5,000-item batch.
.PHONY: test-map-diff-3 test-map-diff-3-script

test-map-diff-3: map-diff-env
	$(MAP_DIFF_PYTHON) -u scripts/test_map_diff_mobile.py $(MAP_DIFF_3_ARGS)

test-map-diff-3-script: map-diff-env
	$(MAP_DIFF_PYTHON) -m unittest discover -s scripts -p 'test_map_diff_mobile_runner.py' -v
