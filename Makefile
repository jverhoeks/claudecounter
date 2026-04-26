BINARY      := claudecounter
PKG         := ./cmd/claudecounter
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

.PHONY: build
build: ## Build for the current platform
	go build -ldflags="$(LDFLAGS)" -o $(BINARY) $(PKG)

.PHONY: install
install: ## go install into $GOBIN
	go install -ldflags="$(LDFLAGS)" $(PKG)

.PHONY: test
test: ## Run all tests
	go test ./...

.PHONY: test-v
test-v: ## Run tests verbosely
	go test -v ./...

.PHONY: cover
cover: ## Run tests with coverage report
	go test -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out | tail -1

.PHONY: fmt
fmt: ## gofmt + go vet
	gofmt -s -w .
	go vet ./...

.PHONY: tidy
tidy: ## go mod tidy
	go mod tidy

.PHONY: run
run: build ## Build and launch the TUI
	./$(BINARY)

.PHONY: once
once: build ## Build and run --once (no TUI)
	./$(BINARY) --once

.PHONY: build-all
build-all: ## Cross-build all platforms (always rebuilds every target)
	@mkdir -p $(DIST)
	@for p in $(PLATFORMS); do \
		goos=$${p%/*}; goarch=$${p#*/}; \
		ext=""; [ "$$goos" = "windows" ] && ext=".exe"; \
		out="$(DIST)/$(BINARY)-$$goos-$$goarch$$ext"; \
		echo "  build $$out"; \
		GOOS=$$goos GOARCH=$$goarch go build -ldflags="$(LDFLAGS)" -o "$$out" $(PKG) || exit 1; \
	done

.PHONY: clean
clean: ## Remove built artefacts
	rm -rf $(BINARY) $(DIST) coverage.out

.PHONY: ccusage-diff
ccusage-diff: build ## Compare today's totals against ccusage
	@echo "=== claudecounter ===" && ./$(BINARY) --once | head -3
	@echo "=== ccusage ===" && npx -y ccusage@latest daily --json 2>/dev/null | \
		python3 -c "import json,sys; d=json.load(sys.stdin); \
		t=next((x for x in d['daily'] if x['date']==__import__('datetime').date.today().isoformat()), None); \
		print(f'Today  \$${t[\"totalCost\"]:.2f}' if t else 'Today  no data')"

.PHONY: release
release: ## Tag VERSION and publish a GitHub release with cross-built binaries
	@if [ "$(VERSION)" = "dev" ]; then echo "VERSION=v0.x.y required, e.g. make release VERSION=v0.2.0"; exit 1; fi
	@echo "Releasing $(VERSION)…"
	$(MAKE) build-all VERSION=$(VERSION)
	git tag -a $(VERSION) -m "claudecounter $(VERSION)"
	git push origin $(VERSION)
	gh release create $(VERSION) \
		--title "$(VERSION)" \
		--generate-notes \
		$(DIST)/$(BINARY)-*

.DEFAULT_GOAL := help
