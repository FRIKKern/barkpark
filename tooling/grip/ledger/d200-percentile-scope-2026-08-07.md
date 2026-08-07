# D200's percentile ban — does it reach a DEFERRAL-WAIT median? (wave 14, [d200-percentile-scope])

Re-derivation recipe. All commands are L1 against `origin/main` @ `77cf2060cf5e69c13da2837c678ae6e9ea47d7e6`.

## 1. D200's full text and its warrant

```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n -A20 '\*\*D200 '
```

Decisive clauses (charter :3839-3847):
- Title scope: "**THE PER-SITE PUBLISH CLOCK** NEEDS A SITE PREDICATE IN THREE SQL CONSTANTS, AND MUST NOT SHIP PERCENTILES."
- Warrant: "the lateral is bounded below and not above (`dr-w12-rv-publish-clock-match-ceiling`), so a site whose next live deploy is three weeks out enters the percentile as a real 20-day measurement"
- Remedy: "Ship BUCKETS plus a censored `waiting >= Xs` lower bound."

## 2. No neighbouring decision narrows or widens it

```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n -A14 -E '\*\*D(190|191|201) '
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n 'D200'   # ONE hit: its own definition
```

D191 widens on a different axis and is itself scoped: "every published **time-to-web** figure carries window + unit + regime boundary + per-site spread". D190 is the clock's justification. D201 is the per-site node's zero-explanation refusal. None mentions deferrals.

## 3. The deferral wait is a DIFFERENT, already-ruled-buildable quantity (D142)

```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n -A16 -E '\*\*D142 '
```

D142 (:2821-2837): "THE JOURNEY METRIC IS BUILDABLE" — publishes **median TTL 0.0 s / p95 364.7 s** fleet-wide and **183 s median TTL** on the contended (≥1 deferral) subset; the key is "a maximal run over `(site_id ORDER BY inserted_at)` terminated by the next live/failed row — segment by RUN, never by rev group". Bounded above by a row already in the table. What D142 REFUSES is the abandoned **RATE**, not the wait median.

## 4. Main already ships a D200-shaped censored deferral wait

```sh
git show origin/main:internal/cli/cloud_site_cmd_test.go | sed -n '2440,2460p'
```

`siteStalenessMap` emits `latest_waiting_seconds_at_least` (censored lower bound), `latest_waiting_deferred`, `latest_waiting_deferral_depth`/`_bound`. The in-test rationale cites **D174/D142**, not D200: "No rate, no percentage, ever: chains have no key and the closed-live rate is era-unstable".

## 5. The collision a builder will hit

Same test, :2455 — any staleness key containing `rate` or `percent` fails. `dr-w13-s5`'s "deferral share" must not be keyed with either word.

```sh
bp task get dr-w13-s5-cli-reads-columns-and-names-its-window -o json
```
s5's criterion asks for WINDOW + DEFERRAL SHARE with denominator. It does **not** ask for a median — the median is new in wave 14's direction.

## Verdict

D200's ban does NOT reach the deferral-wait median. It is scoped, by title and by warrant, to `PublishClock`'s unbounded `LEFT JOIN LATERAL`. The deferral wait is D142's journey — bounded above, already published as a median at fleet scale, already reported per-site as a censored lower bound. Ship the median with (a) run segmentation, (b) censored lower bound for open/truncated/abandoned chains, (c) window + unit + denominator; never as a rate.
