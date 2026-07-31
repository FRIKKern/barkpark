# Re-derivation recipes — cloud-console-hardening W13 verify, free-close-seal (2026-07-31)

Baseline for every recipe: `origin/main` @ `0f28d541e2b8b1412c7f4ee373950443dca7f49c`.
Nothing here reads the local checkout, which was 201 commits behind when these ran.

## R0 — export origin/main's static tree (all browser recipes run against it)

```bash
D=/tmp/w13-verif; rm -rf $D; mkdir -p $D
git archive origin/main cloud/priv/static | tar -x -C $D
```

## R1 — the two overflow-guard runs the assignment mandated

```bash
cd $D/cloud/priv/static
node __preview__/overflow-guard.mjs --defect W12-narrow-viewport-truth
OVERFLOW_GUARD_CLASSIC_SCROLLBARS=1 node __preview__/overflow-guard.mjs --defect W12-narrow-viewport-truth
```
Both print `OVERFLOW GUARD PASS`. The CLASSIC run is the one that answers
gr-backlog-setmatrix-scroll-affordance criterion 1 (its stated blocker was
"never assessed outside --hide-scrollbars").

## R2 — drive #notifications at 768 and print body containment

`drive.mjs` (CDP over `node:` globals, no deps) — kept beside this file's PR if
Decide wants it committed; otherwise re-derive with:

```bash
cd $D/cloud/priv/static && node __preview__/serve.mjs --port 4298 &
# then, in headless Chrome at width 768, on /?scen=notif-configured&theme=light#notifications :
#   document.documentElement.scrollWidth / .clientWidth
#   document.querySelector('.content').clientWidth
#   var w=document.querySelector('.set-matrix'); w.clientWidth; w.scrollWidth;
#   getComputedStyle(w).getPropertyValue('--set-matrix-fade')
#   w.offsetHeight - w.clientHeight            // reserved scrollbar track
```
Measured (CLASSIC scrollbars, origin/main bytes):
`document.scrollWidth 768 == clientWidth 768` (no page-level scroll; the task's
`753` figure is PRE-fix), `.content` 536, scroller 446/520, last column
"Webhook" right 796 vs scroller right 723 at rest, reachable at right 722 after
`scrollLeft := scrollWidth`, `--set-matrix-fade` 48px at rest, reserved track
0px — and that last read is MUTATION-PROVEN able to fail: injecting
`.set-matrix::-webkit-scrollbar{height:12px}` flips 0 -> 12.

## R3 — the .content cliff, swept (the band finding, corroborated)

Same driver, widths 620..900, reading `.content` clientWidth and the scroller's
hidden px. NOTE THE TRAP: navigating the SAME url at successive widths lets
Chrome RESTORE the scroller's scrollLeft, which reads out as a resting
`--set-matrix-fade` of 0px and manufactures a false "the cue is missing"
finding. Bust it with a per-width cache-buster (`&n=<width>`).

| width | `.content` cw | scroller cw/sw | hidden px |
|---|---|---|---|
| 620 | 620 | 546/546 | 0 |
| 700 | 700 | 626/626 | 0 |
| 720 | 720 | 646/646 | 0 |
| 721 | 489 | 399/520 | 121 |
| 740 | 508 | 418/520 | 102 |
| 768 | 536 | 446/520 | 74 |
| 800 | 568 | 478/520 | 42 |
| 860 | 628 | 538/538 | 0 |
| 900 | 668 | 578/578 | 0 |

## R4 — cold deep-link into #activity (the Who axis)

```bash
# headless Chrome @1440 on /?scen=activity&theme=light#activity, read the chips
# that follow the "Who" dim label inside #activity-filters
```
Yields `Everyone | Just me | lin | rex` — the full 3-member roster
(ada=me, lin, rex), at first paint and at +1500ms.

## R5 — the w12 actor-latch tests, and the mutation that reds them

```bash
cd $D/cloud/priv/static
node --test --test-name-pattern "cch-w12-s1" __app.test.mjs        # 3/3 pass
# mutation: drop the failure-clear inside ensureActivityActors
perl -pi -e 's/if \(!r \|\| !r\.ok\) \{ activityActorsTried = false; return; \}/if (!r || !r.ok) { return; }/' app.js
node --test --test-name-pattern "cch-w12-s1" __app.test.mjs        # 1 fails
```

## R6 — the security-gate row's fourth (factual) blocker

```bash
git merge-base --is-ancestor 95ace3150 origin/main && echo on-main
git show origin/main:api/mix.lock | grep '"req"'        # 0.6.3
grep -E '^(id|first_patched_versions|vulnerable_version_ranges)' -A1 \
  ~/.local/share/elixir-security-advisories-mirego/packages/req/*.yml
```
`mix deps.audit` itself is broken on this host (`YamlElixir` not on the CLI's
code path). Drive mix_audit's own entry point instead:

```bash
cat > /tmp/audit.exs <<'EOF'
Path.wildcard("_build/dev/lib/*/ebin") |> Enum.each(&Code.append_path/1)
{:ok, _} = Application.ensure_all_started(:yaml_elixir)
MixAudit.CLI.Audit.run(path: hd(System.argv()), ignore_advisory_ids: "GHSA-4g2h-vm7x-747c")
EOF
mkdir -p /tmp/lock_om && git show origin/main:api/mix.lock > /tmp/lock_om/mix.lock
cd api && elixir /tmp/audit.exs /tmp/lock_om     # "No vulnerabilities found."
```
Drop the `ignore_advisory_ids:` to see the one advisory CI suppresses by name
(esaml GHSA-4g2h-vm7x-747c, no patched release). Point `path:` at the LOCAL
(pre-bump) lock to see both req advisories fire — that is the control.

## R7 — the gate as GitHub actually rendered it

```bash
gh api repos/FRIKKern/barkpark/commits/0f28d541e/check-runs --paginate \
  -q '.check_runs[] | select(.name|test("Security|audit|Sobelow")) | "\(.name) :: \(.conclusion)"' | sort -u
```
`Security gate :: success` while `Sobelow static analysis … :: failure` — the
advisory job is red and the aggregator is green, live, on main's own head.
