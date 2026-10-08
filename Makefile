SHELL := /bin/zsh
.DEFAULT_GOAL := start
.PHONY: start debug clean cloc

start:
	./scripts/run.sh

debug:
	./scripts/run.sh --build-only
	./.build/Cirrus\ Photos.app/Contents/MacOS/SynoTimeline

clean:
	swift package clean
	rm -rf -- ".build/Cirrus Photos.app"

cloc:
	./scripts/cloc.sh
