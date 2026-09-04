# claudecounter — both apps live as siblings under this repo:
#   tui/      Go TUI (the original `claudecounter` binary)
#   macapp/   Swift menu bar app (ClaudeCounterBar.app)
#
# `make` from the repo root drives both. All Go targets `cd tui` first
# so go.mod / go.sum stay scoped to that subdir.

BINARY      := claudecounter
INSIGHTS    := claudeinsights
TUI_DIR     := tui
TUI_PKG     := ./cmd/claudecounter
INSIGHTS_PKG := ./cmd/claudeinsights
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
build: build-insights ## Build the TUI binary for the current platform → ./claudecounter
	cd $(TUI_DIR) && go build -ldflags="$(LDFLAGS)" -o ../$(BINARY) $(TUI_PKG)

.PHONY: build-insights
build-insights: ## Build the analyzer binary → ./claudeinsights
	cd $(TUI_DIR) && go build -ldflags="$(LDFLAGS)" -o ../$(INSIGHTS) $(INSIGHTS_PKG)

.PHONY: install
install: ## go install the TUI into $GOBIN
	cd $(TUI_DIR) && go install -ldflags="$(LDFLAGS)" $(TUI_PKG)


# TZ=UTC pins Go's time.Local for the duration of the test process. The
# limits parity fixture (internal/limits/parity_test.go) compares Go's
# Evaluate(), which hardcodes time.Local, against Swift's
# LimitsParityTests, which pins UTC — so without a fixed TZ here, a
# contributor at UTC+13/+14 (or any non-Amsterdam zone) gets a red suite
# for a timezone mismatch, not a real regression (final-review.md M-2).
# `t.Setenv("TZ", …)` cannot fix this: Go resolves time.Local once at
# process start, before any test runs.
.PHONY: test
test: ## Run all Go tests (TZ=UTC — see comment above)
	cd $(TUI_DIR) && TZ=UTC go test ./...

.PHONY: test-v
test-v: ## Run Go tests verbosely (TZ=UTC — see comment above)
	cd $(TUI_DIR) && TZ=UTC go test -v ./...

.PHONY: cover
cover: ## Run Go tests with coverage report (TZ=UTC — see comment above)
	cd $(TUI_DIR) && TZ=UTC go test -coverprofile=../coverage.out ./...
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

# ────────────────────── M5Stack Core2 firmware (Arduino) ──────────────────────

DEVICE_DIR  := device/core2
DEVICE_FQBN := m5stack:esp32:m5stack_core2
M5_INDEX    := https://static-cdn.m5stack.com/resource/arduino/package_m5stack_index.json
DEVICE_PORT ?= $(shell ls /dev/cu.usbserial-* /dev/cu.wchusbserial* 2>/dev/null | head -1)

.PHONY: device-deps
device-deps: ## Install arduino-cli (brew), the M5Stack core and the sketch's libraries
	@command -v arduino-cli >/dev/null || brew install arduino-cli
	arduino-cli config init --overwrite --additional-urls $(M5_INDEX)
	arduino-cli core update-index
	arduino-cli core install m5stack:esp32
	arduino-cli lib install "M5Unified" "ArduinoJson" "FastLED"

.PHONY: device-build
device-build: ## Compile the Core2 sketch (needs device/core2/secrets.h)
	@test -f $(DEVICE_DIR)/secrets.h || { echo "copy $(DEVICE_DIR)/secrets.example.h to secrets.h and fill it in"; exit 1; }
	arduino-cli compile --fqbn $(DEVICE_FQBN) --output-dir $(DEVICE_DIR)/build $(DEVICE_DIR)

.PHONY: device-flash
device-flash: device-build ## Compile and upload to the first USB serial port (override with DEVICE_PORT=)
	@test -n "$(DEVICE_PORT)" || { echo "no serial port found; plug in the Core2 or set DEVICE_PORT="; exit 1; }
	arduino-cli upload --fqbn $(DEVICE_FQBN) --port $(DEVICE_PORT) --input-dir $(DEVICE_DIR)/build

.PHONY: device-monitor
device-monitor: ## Serial monitor at 115200
	arduino-cli monitor --port $(DEVICE_PORT) --config baudrate=115200

# ────────────────────── meta ──────────────────────

.PHONY: test-all
test-all: test macapp-test ## Run Go + Swift test suites (includes the cross-language limits parity fixture)

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
