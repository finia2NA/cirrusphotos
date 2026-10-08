SHELL := /bin/zsh
.DEFAULT_GOAL := start
.PHONY: start debug clean

start:
	./scripts/run.sh

debug:
	./scripts/run.sh --build-only
	open -na Console
	./.build/Cirrus\ Photos.app/Contents/MacOS/SynoTimeline

clean:
	swift package clean
	rm -rf -- ".build/Cirrus Photos.app"
