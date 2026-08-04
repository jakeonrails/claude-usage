---
name: claude-usage
description: |
  Read the current Claude plan usage — percent used/remaining and time
  elapsed/remaining for the 5-hour session window and the weekly windows —
  as JSON from the ClaudeUsage menubar app's CLI. Use when deciding whether
  to start or defer a large task ("do I have enough quota left?"), when the
  user asks "how much Claude usage do I have left / when does my session
  reset?", or when a scheduler/agent needs to gate work on remaining budget.
---

# claude-usage

The ClaudeUsage menubar app ships a headless `--json` mode that prints the
current usage snapshot to stdout and exits. It reports the **server-enforced**
utilization from Anthropic's `/api/oauth/usage` endpoint — the same numbers
the Claude app shows — so treat it as ground truth, and never try to compute
windows from local JSONL logs instead.

```bash
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --json
```

If that path doesn't exist, the app isn't installed — tell the user to
download the DMG from https://github.com/jakeonrails/claude-usage/releases/latest
(drag into Applications), or build from source with `./install.sh` from
https://github.com/jakeonrails/claude-usage.

## Why polling is safe

The command is **cache-first**: the menubar app already refreshes an on-disk
snapshot (`~/Library/Application Support/ClaudeUsage/last_usage.json`) every
5 minutes, and `--json` serves that file while it's fresher than `--max-age`
(default 360 s). While the app is running, a poll is a pure file read — no
keychain, no network, no rate-limit cost. Only when the cache is stale (the
app isn't running) does the CLI fetch from the API itself, using the app's
own stored credentials.

Poll it as often as you like with the defaults. Do **not** use `--fresh` in
loops — it bypasses the cache and burns the per-token rate-limit budget.

## Flags

| Flag | Meaning |
|---|---|
| `--json` | required; selects headless mode |
| `--max-age <seconds>` | serve cached data up to this old (default 360) |
| `--fresh` | skip the cache, fetch now (rate-limit risk — avoid in loops) |

## Exit codes — check these

| Code | Meaning |
|---|---|
| 0 | fresh data printed (from cache or API) |
| 2 | not connected — user must open the menubar app and connect their account |
| 3 | fetch failed but **stale** cached data was printed (`"stale": true`, see `"error"`) |
| 1 | fetch failed and no cache exists (error JSON on **stderr**) |
| 64 | bad arguments |

Exit 3 still prints usable JSON — stale data beats no data for sizing a task,
but note the `age_seconds` before trusting it.

## Output shape

stdout is pure JSON (diagnostics go to stderr). Null fields are **omitted**,
not emitted as `null` — e.g. `error` only appears when stale, and windows the
plan doesn't report are absent entirely:

```json
{
  "source": "cache",            // "cache" | "api"
  "stale": false,               // true only on exit 3 (then "error" is present)
  "fetched_at": "2026-06-12T16:16:42Z",
  "age_seconds": 147,
  "five_hour": {
    "active": true,
    "used_percent": 40,
    "remaining_percent": 60,
    "resets_at": "2026-06-12T19:09:59.931478+00:00",
    "window_seconds": 18000,
    "elapsed_seconds": 7750,
    "remaining_seconds": 10250
  },
  "seven_day": { "...": "same shape" },
  "seven_day_opus": { "...": "same shape" },
  "seven_day_sonnet": { "...": "same shape" },
  "seven_day_fable": { "...": "same shape" },
  "extra_usage": { "enabled": false }
}
```

Field semantics:

- **`five_hour`** — the rolling 5-hour session window (the one that usually
  gates interactive work). **`seven_day`** — the overall weekly window.
  The per-model weeklies (`seven_day_opus`, `seven_day_sonnet`,
  `seven_day_fable`) appear only on plans that report them — a missing key
  means the plan doesn't expose it, not zero usage.
- **`active: false`** means the previous window reset and no new one has
  started: true usage right now is 0% (`used_percent: 0`,
  `resets_at`/`elapsed_seconds`/`remaining_seconds` are null). A fresh window
  starts with the next request.
- **`used_percent`** vs **`elapsed_seconds`**: if
  `used_percent > 100 * elapsed_seconds / window_seconds`, quota is being
  burned faster than the clock — the session will cap out before it resets.

## Recipes

Gate a big task on session headroom:

```bash
usage() { /Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --json; }

# only proceed if ≥50% of the 5-hour session remains
usage | jq -e '.five_hour.remaining_percent >= 50' >/dev/null && start-big-task
```

One-line human summary:

```bash
usage | jq -r '"session \(.five_hour.used_percent)% used, resets \(.five_hour.resets_at); week \(.seven_day.used_percent)%"'
```

Seconds until the session resets (0 if between sessions):

```bash
usage | jq '.five_hour.remaining_seconds // 0'
```

Handle every exit code:

```bash
out=$(usage); code=$?
case $code in
  0) ;;                                        # trust the data
  3) echo "stale ($(jq -r .age_seconds <<<"$out")s old): $(jq -r .error <<<"$out")" >&2 ;;
  2) echo "ClaudeUsage not connected — open the menubar app" >&2; exit 1 ;;
  *) echo "usage fetch failed" >&2; exit 1 ;;
esac
```

## Gotchas

- Use the full bundle path; the binary is not on `$PATH`. Running it with no
  flags launches the GUI — always pass `--json`.
- Percentages are the server's `utilization` values; the CLI clamps them to
  0–100.
- `null`-safe jq: prefer `.five_hour.remaining_percent // 0` when a window
  might be absent or inactive.
- Exit 1's error JSON is on **stderr**, not stdout.
