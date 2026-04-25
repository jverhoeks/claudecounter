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

## Accuracy and limitations

This tool sums what's in the JSONL using Anthropic's documented billing
formula (`input × rate + cache_creation × rate + cache_read × rate +
output × rate`) with last-seen-wins dedupe by `message.id`.

Two things to know:

- **`usage.input_tokens` in the JSONL is post-cache residual**, not total
  API input. It's typically small (single-digit to low-thousands per turn).
  The bulk of real input tokens is in `cache_read_input_tokens`. The cache
  fields are reliable; the non-cache input/output fields include streaming
  placeholder writes in most lines. See
  [gille.ai post on JSONL undercounting](https://gille.ai/en/blog/claude-code-jsonl-logs-undercount-tokens/).
- **Different tools produce different dollar totals** from the same JSONL.
  ccusage, codeburn, and this tool will disagree by 10-30% on any given day
  because they dedup differently and include/exclude different event
  classes. None is verifiable against anything except Anthropic's billing
  dashboard.

Pricing table mirrors [LiteLLM's](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)
for the Claude 4.5/4.6/4.7 family (which is what ccusage uses). Override
via `pricing.toml`.

## Tests

```
go test ./...
```
