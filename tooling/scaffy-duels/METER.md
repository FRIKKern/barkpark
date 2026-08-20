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

<!-- meter:population 34 -->

Verified 2026-08-05: reproduces `total_cost_usd` **exactly (rel err < 1e-6) on
34/34** recorded duel envelopes. `meter.py verify` re-runs this check; any
mismatch means rates, tier, or TTL changed — investigate before publishing.
That literal and the `meter:population` marker above are both machine-read by
`meter.py verify`, which reds if they disagree with each other or with the
number of envelopes actually on disk — see §5.

**The 24% trap:** cache writes are priced by TTL — 5-minute TTL at 1.25×, 1-hour
TTL at **2×**. Claude Code sessions here use the 1-hour TTL, so assuming the
textbook 1.25× silently under-reports every figure by ~a quarter. Always read
the split from `usage.cache_creation`, never assume.

Rates (from the Anthropic pricing table, cached 2026-06; re-verify via the
`claude-api` skill or platform.claude.com/docs/en/pricing before publishing):

| model prefix        | in $/MTok | out $/MTok |
|---------------------|-----------|------------|
| claude-fable-5      | 10.00     | 50.00      |
| claude-opus-5       | 5.00      | 25.00      |
| claude-opus-4-*     | 5.00      | 25.00      |
| claude-sonnet-5     | 3.00      | 15.00      |
| claude-sonnet-4-6   | 3.00      | 15.00      |
| claude-haiku-4-5    | 1.00      | 5.00       |

A model absent from this table is a **refusal**, never a zero: `meter.py verify`
reds on it, and `tally_wf.py` exits 1 with `total_usd_complete: false` rather
than reporting a total with that model's dollars silently dropped. Until
2026-08-05 `claude-opus-5` — the model this repo's own waves run on — matched no
prefix in either table.

(Batch API halves everything; sub-agent/CLI work here is interactive, standard tier.)

## 3. What the money actually is — measured structure

**Two statistics, each stamped with its population.** A single share number here
is not safe to quote: the per-envelope median and the cost-weighted share
disagree about which lever matters, and the disagreement is the finding, not a
rounding artifact. The 24 column is the frozen control — the corpus this section
was first computed over (commit `04893e486`) — kept so the retake is checkable.

| component        | median share, n=24 | median share, n=34 | by dollars, n=24 ($17.08) | by dollars, n=34 ($66.40) |
|------------------|--------------------|--------------------|---------------------------|---------------------------|
| cache **writes** | **58.8%**          | 55.0%              | 46.9%                     | **24.2%**                 |
| cache reads      | 32.5%              | 36.8%              | 43.5%                     | **66.4%**                 |
| output tokens    | 7.9%               | 9.5%               | 9.6%                      | 9.3%                      |
| fresh input      | ~0%                | ~0%                | ~0%                       | 0.1%                      |

**The median barely moves; the dollars invert.** Adding ten envelopes shifts the
median by 3.8pp and leaves the lever order unchanged — but by dollars, writes
drop from 46.9% to 24.2% while reads climb from 43.5% to 66.4%. Reads become the
majority of spend. The cause is visible in the arrivals: they are long S-tier
sessions rather than short warm-worktree duels (`stier-round1--4blocks` alone is
$16.30 at writes 10.7 / reads 80.6). The median treats a $0.55 duel and a $16.30
session as one vote each; the dollars do not.

So the LEVER column below is derived from the median over short duel cells, and
it does **not** describe where the money goes on the long sessions this repo now
runs. On those, the top lever is fewer tool-call round-trips, not fewer spawns.
Say which statistic and which population you mean, every time.

| component            | median share (n=24) | lever |
|----------------------|--------------|-------|
| cache **writes**     | **58.8%**    | fewer spawns; less new context per turn (tool results, file dumps) |
| cache reads          | 32.5%        | fewer tool-call round-trips (full context re-reads each turn) |
| output tokens        | 7.9%         | terser output; rarely the bottleneck |
| fresh input          | ~0%          | noise |

Consequences, all measured in this repo:
- **The spawn floor is ~$0.55** (Sonnet-5, warm repo): one fresh agent pays the
  prefix cache-write bill before doing any work. Comparing arms below ~2× the
  floor measures the floor, not the work. Re-derived 2026-08-05 and unchanged:
  median envelope cost is $0.5451 (n=24) and $0.5857 (n=34) — the ten arrivals
  move the median cost by 4c, so figures downstream of the floor are not stale.
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
  all-exact. A single mismatch blocks publication of any dollar figure. Since
  2026-08-05 the **exit code** carries that rule — see §5.

## 5. Why this standard rotted anyway (2026-08-05)

**This instrument was fast, self-proving, and non-vacuous — and it rotted, purely
because no gate ever ran it.** `meter.py verify` completes in 0.065s. It ships a
`--self-test` that deliberately proves the verifier reds on a 1.25×-trap fixture,
so it is not vacuously green. It was correct on every envelope it walked. And on
2026-08-05 it printed `34 envelopes — 34 exact` against a §2 that said `24/24`
and a §3 computed "across the 24 duel envelopes": the corpus had grown 24 → 34
across six commits and the literals never followed. `grep -rn meter
.github/workflows/` returns rc=1 over 43 workflow files — zero gates call it —
and the PDS door census never enumerated it. **The instrument is not the
mechanism; being run is.** A price doc with a perfect executable half and no
caller drifts exactly as fast as one with no instrument at all.

Three things changed so that the drift cannot recur silently, all in the exit
code rather than in prose a reader has to notice:

- **The instrument asserts its own population.** `verify` compares the envelope
  count it walked against the figure this doc publishes (§2's marker and prose
  literal, which must agree with each other) and reds on any disagreement,
  naming the delta. Asserted for the canonical `results/` corpus only.
- **`exact` is the only pass.** Three paths previously returned rc=0 while
  asserting a number nothing had measured: a multi-model envelope (the identity
  sum cannot detect a uniformly-scaled total), an envelope with no `modelUsage`
  at all, and — because the glob was one level deep — an envelope nested in a
  subdirectory, which was simply never walked. The first two now refuse; the
  third is walked recursively.
- **The mirrored rate table is asserted, not trusted.** `tally_wf.py` keeps its
  own copy of RATES on purpose (so it stays a single copyable file), and
  `--self-test` now proves the two are identical. The drift this catches was
  real: both tables were missing `claude-opus-5`, and `tally_wf.py` responded to
  an unrated model by dropping its dollars and returning 0.

**Still unwired, deliberately.** Nothing here adds a CI workflow: gating this
requires first deciding whether `results/` is a corpus CI may walk, which is a
decision and not a build step. Until that is made, the rule remains "run it
before you publish a dollar figure" — and the lesson above is what that costs.
