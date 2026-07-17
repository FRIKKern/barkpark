<!-- doc-tier: human | canonical-for: token-cost-measurement | budget: 6000tok -->
# METER.md — the token-spend & cost measurement standard

Every dollar or token figure published from this repo (duels, benchmarks, papers)
MUST come from this standard. It exists because plausible-looking numbers are easy
and verified numbers are not: our first formula pass underestimated real spend by
**~24%** until the cache-write TTL was accounted for.

## 1. Ground truth hierarchy

1. **`total_cost_usd` from the `claude` CLI JSON envelope** (`--output-format json`,
   or the last line of `stream-json`). This is the meter of record. Per-model
   breakdown: `modelUsage[<model>].costUSD` — these sum exactly to `total_cost_usd`.
2. **`usage` from the same envelope** for token axes:
   `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
   `cache_creation.ephemeral_1h_input_tokens` / `.ephemeral_5m_input_tokens`.
3. **Agent-tool telemetry** (`subagent_tokens`, `duration_ms`) — token axis only,
   when a cell runs as a subagent instead of a CLI spawn; it carries no dollars,
   so convert via §3 and label the figure "computed", never "reported".
4. **API `usage` object** (`response.usage`) when calling the API directly —
   same fields; total prompt size = `input_tokens + cache_creation_input_tokens
   + cache_read_input_tokens` (`input_tokens` is the *uncached remainder only*).

**Banned:** naively summing `usage` across transcript JSONL lines. Retries and
stream duplicates overcount 2–5×. The only valid transcript-derived number is
deduped by message id, and even then the envelope wins on any disagreement.

**Banned:** estimating token counts with tiktoken or chars/4. To count tokens in
content, use `POST /v1/messages/count_tokens` against the *same model id* —
counts are tokenizer-specific (Sonnet 5's tokenizer yields ~30% more tokens than
Sonnet 4.6 for identical text).

## 2. The verified cost formula

For a single-model envelope (rates in $/MTok, standard tier):

```
cost = ( input_tokens                    × rate_in
       + output_tokens                   × rate_out
       + ephemeral_5m_input_tokens       × rate_in × 1.25
       + ephemeral_1h_input_tokens       × rate_in × 2.00
       + cache_read_input_tokens         × rate_in × 0.10 ) / 1_000_000
```

Verified 2026-07-18: reproduces `total_cost_usd` **exactly (rel err < 1e-6) on
24/24** recorded duel envelopes. `meter.py verify` re-runs this check; any
mismatch means rates, tier, or TTL changed — investigate before publishing.

**The 24% trap:** cache writes are priced by TTL — 5-minute TTL at 1.25×, 1-hour
TTL at **2×**. Claude Code sessions here use the 1-hour TTL, so assuming the
textbook 1.25× silently under-reports every figure by ~a quarter. Always read
the split from `usage.cache_creation`, never assume.

Rates (from the Anthropic pricing table, cached 2026-06; re-verify via the
`claude-api` skill or platform.claude.com/docs/en/pricing before publishing):

| model prefix        | in $/MTok | out $/MTok |
|---------------------|-----------|------------|
| claude-fable-5      | 10.00     | 50.00      |
| claude-opus-4-*     | 5.00      | 25.00      |
| claude-sonnet-5     | 3.00      | 15.00      |
| claude-sonnet-4-6   | 3.00      | 15.00      |
| claude-haiku-4-5    | 1.00      | 5.00       |

(Batch API halves everything; sub-agent/CLI work here is interactive, standard tier.)

## 3. What the money actually is — measured structure

Median cost shares across the 24 duel envelopes (agent cells, warm worktrees):

| component            | median share | lever |
|----------------------|--------------|-------|
| cache **writes**     | **58.8%**    | fewer spawns; less new context per turn (tool results, file dumps) |
| cache reads          | 32.5%        | fewer tool-call round-trips (full context re-reads each turn) |
| output tokens        | 7.9%         | terser output; rarely the bottleneck |
| fresh input          | ~0%          | noise |

Consequences, all measured in this repo:
- **The spawn floor is ~$0.55** (Sonnet-5, warm repo): one fresh agent pays the
  prefix cache-write bill before doing any work. Comparing arms below ~2× the
  floor measures the floor, not the work.
- **Tool-call count is a cost multiplier**: every round-trip re-reads the whole
  context as cache-read (0.1×) and writes the new turn (2×). An agent that does a
  chore in 39 calls vs 69 calls saves real money even at identical output tokens.
- **Output-token deltas understate engine wins**: `bp scaffy run` costs $0 and
  ~seconds; agent arms pay the floor regardless of how little they type.

## 4. Procedure rules (what makes two numbers comparable)

- **One envelope per cell.** Each measured unit = one `claude -p … --output-format
  json` spawn; its envelope is the record. No sharing sessions across cells.
- **Serial cells** (D66): concurrent cells poison each other's prompt cache and
  the host. One at a time; the validator asserts a non-overlapping timeline.
- **Cold vs warm is a variable** (D83): first spawn on a prefix pays cache-write;
  later spawns read it at 0.1×. Either report cold and warm separately or keep
  all arms at the same temperature. Never mix.
- **Separate fixed gates from variable work**: build/test gates cost the same in
  every arm; report them apart so they don't drown the delta (fixed-gate
  dominance falsified our 90% prediction once).
- **Caps are registered before running** (prereg): each cell carries `cap_usd`;
  the validator reds on overspend and on cap mis-registration.
- **Time axes**: wall-clock = envelope `duration_ms`; API time = `duration_api_ms`;
  `num_turns` is the round-trip count. Report all three — they diverge and each
  tells a different story (§3).
- **Verify before publish**: `python3 meter.py verify results/` must print
  all-exact. A single mismatch blocks publication of any dollar figure.
