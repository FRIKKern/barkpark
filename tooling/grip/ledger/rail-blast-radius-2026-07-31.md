# Re-derivation recipes — rail blast radius (Cloud Console Hardening wave 13, 2026-07-31)

Verifier lane `rail-blast-radius`. Question: exactly which byte-locked assertions
break when a per-row provenance field lands on the provision/deploy step rail,
and does the numeric ETA mount on ONE screen or two?

Everything below was run against **`origin/main` bytes only**
(`0f28d541e2b8b1412c7f4ee373950443dca7f49c`), materialised into a scratch tree —
the working checkout is BEHIND `origin/main` on `cloud/priv/static` (2942 lines),
so running the harness in place would have measured the wrong file.
**No repo file outside this ledger row was written.** All mutations were applied
to the scratch copy and reverted; the scratch baseline was re-proven green
(741/741) after every variant.

Setup (required — the harness reads Go golden fixtures OUTSIDE `cloud/`, and a
partial extract produces two ENOENT reds that look like real failures):

```
mkdir -p /private/tmp/rail-verify/om
git archive origin/main cloud/priv/static internal/taskboard/testdata internal/pdrender/testdata | tar -x -C /private/tmp/rail-verify/om
cd /private/tmp/rail-verify/om/cloud/priv/static
```

| # | Claim | Command |
|---|---|---|
| 1 | Baseline at origin/main is **741 pass / 0 fail**; `app.js` parses clean | `node --check app.js; node __app.test.mjs` |
| 2 | The brief's `--test-name-pattern 'byte-locked'` matches **NOTHING** — no test carries that name; the run reports `pass 1` (the FILE), a vacuous green | `node --test --test-name-pattern 'byte-locked' __app.test.mjs`; `grep -n 'test("' __app.test.mjs \| grep -i byte-lock` |
| 3 | The byte-lock is a SECTION at `__app.test.mjs:3063`, not `:2637-2690` (that range is `esc` + `dwb-18` + `failureCopy`) | `git show origin/main:cloud/priv/static/__app.test.mjs \| sed -n '3063,3128p'` |
| 4 | Only TWO assertions are full-string `assert.equal(html, …)` HTML locks, both on `newStepsHtml` (lines 3074, 3092) | `grep -n 'assert.equal(html,' __app.test.mjs` |
| 5 | **Variant A** (per-row `paceSource` + a rendered `data-pace` attribute on the `<li>`): 741 → **733 pass / 8 fail**. Tests 164, 165, 167, 188, 190, 191, 610, 611 | patch `newStepsHtml`'s `<li …>` emitter + `deployRailRows`'s row literal, then `node __app.test.mjs` |
| 6 | **Variant C** (blanket honest indeterminacy — no ETA text, no `aria-valuenow`, no pending `~Ns` hint anywhere): **740 / 1 fail** (test 166 only) | patch `overallEtaText`, `provisionOverallHtml`'s track, and the pending arm of `newStepsHtml`'s `time` |
| 7 | **Variant D** (SCOPED indeterminacy — a `paceSource` row field gates the numeric promise, **no new markup attribute**): **739 / 2 fail** (tests 164, 166) — the cheapest honest shape | patch `deployRailRows` + the `active`/`pending` arms of `newStepsHtml`'s `time` |
| 8 | `__css_check.mjs` is green at origin/main (0 errors) and stays green under variant A — but its **E2** rule fails any NEW CLASS emitted without an `app.css` rule, so a class-carried provenance costs a CSS rule too | `node __css_check.mjs` |
| 9 | The numeric ETA mounts on **TWO** screens: `newRenderProgress` (app.js:14824, :14856) and `instanceTimelineHtml` (app.js:14051). `timelineHtml` itself carries NO bar | `node __drive_surfaces.mjs` (drives `instanceTimelineHtml` off a real bp payload → `aria-valuenow="49"`, `about 1m 0s left`) |
| 10 | `newStepsHtml` has **8 call sites / 6 surfaces**: `deployRailHtml`, `newProgressStepsHtml`, `newRenderFailed`, `offloadWatchPanelHtml`, `supportRowHtml`, `timelineHtml`, `tickInstanceTimeline`, `patchInstanceTimeline` | `grep -n 'newStepsHtml(' app.js` + walk back to the enclosing `function` |
| 11 | `supportRowHtml` renders **4** constant-paced `~Ns` hints and is covered by NO test that pins them — variant D silently changes it | `node __drive_surfaces.mjs` |
| 12 | `stepRingProgress` returns the identical fraction for a measured and a constant budget (0.9009 / 0.4050 on both rails) and no row key matches `/provenance\|source\|measured\|median/` on either producer | `node __drive_rail2.mjs` |
| 13 | The server publishes **only** `step_estimates.deploy`; no `provision_stage_estimates` exists anywhere in `cloud/` | `git grep -n 'step_estimates\|_stage_estimates' origin/main -- cloud/ \| grep -v priv/static` |

The three drive harnesses (`__drive_rail.mjs`, `__drive_rail2.mjs`,
`__drive_surfaces.mjs`) are scratch-only and were NOT committed; each is a copy
of `__app.test.mjs`'s `node:vm` sandbox bootstrap (lines 29-81) plus a printer.
