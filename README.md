# claudecounter

Realtime cost dashboard for Claude Code. Tails `~/.claude/projects/**/*.jsonl`
and shows today's and this-month's spend, total and per-model, across three
togglable views.

## Build

```
go build ./cmd/claudecounter
```

## Run

```
./claudecounter
```

Flags:
- `--pricing <path>` — override pricing TOML location (default:
  `~/.config/claudecounter/pricing.toml`)
- `--root <path>` — override projects root (default: `~/.claude/projects`)
- `--refresh-pricing` — fetch current prices from the Anthropic docs and
  overwrite the pricing file

## Keys

- `1` / `2` / `3` — minimal / split / full view
- `Tab` — cycle views
- `q` / `Ctrl+C` — quit

## Pricing

On first run, if `pricing.toml` does not exist, claudecounter attempts to
fetch prices from `https://docs.anthropic.com/en/docs/about-claude/pricing`
and write them to disk. If the fetch fails, it falls back to a baked-in
table (dated in source) with a banner warning.

## Tests

```
go test ./...
```
