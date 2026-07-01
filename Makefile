# 7zip-swiftui — dev tasks
#
# Note on toolchains: the app is built with the Command Line Tools SDK (via
# scripts/build.sh), but the CLT SDK lacks XCTest, so `test` runs under the
# full Xcode toolchain. The two toolchains produce incompatible module caches,
# so tests use a separate scratch dir (.build/xctest) to avoid poisoning the
# .build tree that build.sh uses.

XCODE_DEV := /Applications/Xcode.app/Contents/Developer
APP       := .build/YAUnarchiver.app

.DEFAULT_GOAL := help

.PHONY: help build release run test clean fetch-7zz

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the debug .app bundle (.build/YAUnarchiver.app)
	./scripts/build.sh

release: ## Build the release .app bundle
	./scripts/build.sh release

run: build ## Build, then launch the app
	open $(APP)

test: ## Run the unit test suite (Xcode toolchain, isolated scratch dir)
	DEVELOPER_DIR=$(XCODE_DEV) swift test --scratch-path .build/xctest

clean: ## Remove all build artifacts
	rm -rf .build

fetch-7zz: ## Re-download the bundled 7zz binary (maintenance only)
	./scripts/fetch-7zz.sh
