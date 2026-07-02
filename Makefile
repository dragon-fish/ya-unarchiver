# YA Unarchiver — dev tasks (XcodeGen + xcodebuild)

PROJECT := YAUnarchiver.xcodeproj
SCHEME  := YAUnarchiver
DERIVED := .build/DerivedData
APP     := $(DERIVED)/Build/Products/Debug/YAUnarchiver.app

# The system `xcode-select` may point at the Command Line Tools, whose `xcodebuild`
# can't build app targets. Pin xcodebuild to the full Xcode toolchain here so the
# Makefile works regardless of the global selection (no sudo / xcode-select needed).
XCODE_DEV := /Applications/Xcode.app/Contents/Developer
XCODEBUILD := DEVELOPER_DIR=$(XCODE_DEV) xcodebuild

.DEFAULT_GOAL := help
.PHONY: help generate build run test clean fetch-7zz

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

$(PROJECT): project.yml ## Generate the Xcode project from project.yml
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found — run: brew install xcodegen"; exit 1; }
	xcodegen generate

generate: $(PROJECT) ## Generate the Xcode project (regenerate if project.yml changed)

fetch-7zz: ## Re-download the bundled 7zz binary (maintenance only)
	./scripts/fetch-7zz.sh

build: generate ## Build the debug .app bundle
	@test -f Resources/7zz || ./scripts/fetch-7zz.sh
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build

run: build ## Build, then launch the app
	open $(APP)

test: generate ## Run the unit test suite via xcodebuild (Xcode toolchain)
	$(XCODEBUILD) test -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED)

clean: ## Remove all build artifacts (.build, incl. DerivedData)
	rm -rf .build
