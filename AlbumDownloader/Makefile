SHELL := /bin/zsh
.DEFAULT_GOAL := build
.PHONY: build test project clean

DERIVED := build/DerivedData
BINARY := build/album-downloader

# Universal (Apple silicon and Intel) release binary at build/album-downloader.
build:
	xcodebuild -project AlbumDownloader.xcodeproj -scheme album-downloader -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath '$(DERIVED)' -quiet build
	cp '$(DERIVED)/Build/Products/Release/album-downloader' '$(BINARY)'
	@lipo -archs '$(BINARY)'
	@echo "Built $(BINARY)"

test:
	xcodebuild -project AlbumDownloader.xcodeproj -scheme album-downloader -destination 'platform=macOS' -derivedDataPath '$(DERIVED)' -quiet test

# Regenerates AlbumDownloader.xcodeproj from project.yml (needs XcodeGen).
project:
	xcodegen generate

clean:
	rm -rf build
