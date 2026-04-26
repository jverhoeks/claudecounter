# claudecounter — both apps live as siblings under this repo:
#   tui/      Go TUI (the original `claudecounter` binary)
#   macapp/   Swift menu bar app (ClaudeCounterBar.app)
#
# `make` from the repo root drives both. All Go targets `cd tui` first
# so go.mod / go.sum stay scoped to that subdir.

BINARY      := claudecounter
TUI_DIR     := tui
TUI_PKG     := ./cmd/claudecounter
DIST        := dist
VERSION     ?= dev
LDFLAGS     := -s -w -X main.version=$(VERSION)

# All cross-compile targets. Format: <goos>/<goarch>
PLATFORMS := \
	darwin/arm64 \
	darwin/amd64 \
	linux/amd64 \
	linux/arm64 \
	windows/amd64 \
	windows/arm64

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ────────────────────── TUI (Go) ──────────────────────

.PHONY: build
build: ## Build the TUI binary for the current platform → ./claudecounter
	cd $(TUI_DIR) && go build -ldflags="$(LDFLAGS)" -o ../$(BINARY) $(TUI_PKG)

.PHONY: install
install: ## go install the TUI into $GOBIN
	cd $(TUI_DIR) && go install -ldflags="$(LDFLAGS)" $(TUI_PKG)

.PHONY: test
test: ## Run all Go tests
	cd $(TUI_DIR) && go test ./...

.PHONY: test-v
test-v: ## Run Go tests verbosely
	cd $(TUI_DIR) && go test -v ./...

.PHONY: cover
cover: ## Run Go tests with coverage report
	cd $(TUI_DIR) && go test -coverprofile=../coverage.out ./...
	go tool cover -func=coverage.out | tail -1

.PHONY: fmt
fmt: ## gofmt + go vet (TUI module)
	cd $(TUI_DIR) && gofmt -s -w .
	cd $(TUI_DIR) && go vet ./...

.PHONY: tidy
tidy: ## go mod tidy (TUI module)
	cd $(TUI_DIR) && go mod tidy

.PHONY: run
run: build ## Build and launch the TUI
	./$(BINARY)

.PHONY: once
once: build ## Build and run --once (no TUI)
	./$(BINARY) --once

.PHONY: build-all
build-all: ## Cross-build TUI for all platforms (always rebuilds every target)
	@mkdir -p $(DIST)
	@for p in $(PLATFORMS); do \
		goos=$${p%/*}; goarch=$${p#*/}; \
		ext=""; [ "$$goos" = "windows" ] && ext=".exe"; \
		out="$(DIST)/$(BINARY)-$$goos-$$goarch$$ext"; \
		echo "  build $$out"; \
		( cd $(TUI_DIR) && GOOS=$$goos GOARCH=$$goarch go build -ldflags="$(LDFLAGS)" -o "../$$out" $(TUI_PKG) ) || exit 1; \
	done

# ────────────────────── macOS menu bar app (Swift) ──────────────────────

.PHONY: macapp
macapp: ## Build the macOS menu bar app (.app bundle → dist/)
	./macapp/scripts/build-app.sh release

.PHONY: macapp-debug
macapp-debug: ## Build a debug .app for fast iteration
	./macapp/scripts/build-app.sh debug

.PHONY: macapp-test
macapp-test: ## Run Swift unit tests for the macapp core library
	cd macapp && swift test

.PHONY: macapp-run
macapp-run: macapp ## Build and launch the menu bar app
	open $(DIST)/ClaudeCounterBar.app

.PHONY: macapp-release
macapp-release: ## Package macapp as a distributable .zip + .sha256 (use VERSION=v1.0.0)
	VERSION=$(VERSION) ./macapp/scripts/release-macapp.sh

.PHONY: macapp-publish
macapp-publish: ## Tag macapp-VERSION + push (CI builds + creates GitHub Release)
	@if [ "$(VERSION)" = "dev" ]; then \
		echo "VERSION=v1.0.0 required, e.g. make macapp-publish VERSION=v1.0.0"; exit 1; \
	fi
	git tag -a macapp-$(VERSION) -m "ClaudeCounterBar $(VERSION)"
	git push origin macapp-$(VERSION)
	@echo "Tag pushed. Watch the release build at:"
	@echo "  https://github.com/jverhoeks/claudecounter/actions"

# ────────────────────── meta ──────────────────────

.PHONY: test-all
test-all: test macapp-test ## Run Go + Swift test suites

.PHONY: clean
clean: ## Remove built artefacts (both apps)
	rm -rf $(BINARY) $(DIST) coverage.out
	rm -rf macapp/.build macapp/.swiftpm

.PHONY: ccusage-diff
ccusage-diff: build ## Compare today's totals against ccusage
	@echo "=== claudecounter ===" && ./$(BINARY) --once | head -3
	@echo "=== ccusage ===" && npx -y ccusage@latest daily --json 2>/dev/null | \
		python3 -c "import json,sys; d=json.load(sys.stdin); \
		t=next((x for x in d['daily'] if x['date']==__import__('datetime').date.today().isoformat()), None); \
		print(f'Today  \$${t[\"totalCost\"]:.2f}' if t else 'Today  no data')"

.PHONY: release
release: ## Tag vX.Y.Z and trigger CI to build BOTH apps + create the joint Release
	@if [ "$(VERSION)" = "dev" ]; then \
		echo "VERSION=vX.Y.Z required, e.g. make release VERSION=v1.0.0"; exit 1; \
	fi
	@echo "Tagging joint release $(VERSION) (TUI + macapp ship together)…"
	git tag -a $(VERSION) -m "claudecounter $(VERSION)"
	git push origin $(VERSION)
	@echo
	@echo "✓ Tag pushed. CI will build both apps and publish the Release."
	@echo "  Watch: https://github.com/jverhoeks/claudecounter/actions"
	@echo "  Result: https://github.com/jverhoeks/claudecounter/releases/tag/$(VERSION)"

.PHONY: release-local
release-local: ## Local cross-build of just the TUI (skips CI). Useful for testing build-all.
	@if [ "$(VERSION)" = "dev" ]; then \
		echo "VERSION=vX.Y.Z required, e.g. make release-local VERSION=v1.0.0"; exit 1; \
	fi
	$(MAKE) build-all VERSION=$(VERSION)
	@echo "✓ TUI binaries in $(DIST)/. Did NOT tag, push, or create a release."

.DEFAULT_GOAL := help
