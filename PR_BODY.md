Adds [ethanwong-hk/dsh-thinking-guard](https://github.com/ethanwong-hk/dsh-thinking-guard) to **Development & Runtime**.

## What it does

A circuit breaker for idle agent turns. It watches `agent/assistant-stream` and cancels a turn that produces only reasoning — no text, no tool call — on three independent gates:

| Gate | Default | Condition |
|---|---|---|
| `thinking-only-timeout` | 45000 ms | zero text and zero tool-call, measured from the **last progress** rather than attempt start |
| `thinking-volume` | 80000 chars | reasoning volume in one attempt, **independent of whether text was produced** |
| `degenerate-loop` | 3 repeats | exact repeat unit / sentence-template repeat / sparse repeat / 6-gram density |

On trip it calls `agent.cancel()` and injects a continue instruction that requires the next action to be a tool call, so the task resumes instead of stalling.

## Why

- `dsh-agent-loop` decides termination only **after the stream ends** — if the stream never ends, `turn/end` is never written
- `dsh-llm-deepseek` idle watchdog measures **connection liveness, not task progress** — it re-arms on every SSE event, so continuous reasoning output never trips it

Together these leave a reasoning-only turn unable to stop itself.

## Repository requirements

- `dsh.bundle` manifest with `patch: ./cordis.patch.yml` — declared, and the patch file is at the repo root
- `dsh-plugin` topic — added
- Real, working code — 435 lines in `lib/index.js` plus an 11-case regression suite in `test/guard.test.mjs` (89 lines; `npm test` passes 11/11)
- Every number above is from `DEFAULTS` in `lib/index.js`

## Note on repo age

Local run of `scripts/check-submission.mjs --base origin/main` reports the age bar as the only failing check, and states it re-runs and clears on its own — so this is submitted now rather than held back.

The entry file was renamed alongside an account rename (`lemssh77` → `ethanwong-hk`) so the filename, `url` and `name` all still match the repository.

## Self-reported defect

An earlier internal revision had `formatNotice` referencing an out-of-scope `cfg` in the `sparse-repeat` branch, which threw before `agent.cancel()` and left that gate inert for 11 days (1543 occurrences in the host log). Fixed, with a regression case added — noted here since it bears on whether the code does what the entry claims.
