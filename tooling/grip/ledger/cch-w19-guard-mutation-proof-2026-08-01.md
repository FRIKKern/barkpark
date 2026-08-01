# cch-w19 overflow-guard mutation proof — the guard is proven able to LOSE (2026-08-01)

Slice `cch-w19-s1-guard-loses-in-ci`, Cloud Console Hardening wave 19. Wave 18 gave
`cloud/priv/static/__preview__/overflow-guard.mjs` a CI job after five waves of assertions
sat in a file nothing ran. The job's EXISTENCE was verified structurally; what was never
driven is that it can **lose** — and a wiring slice that cannot be shown to fail is exactly
the disease it was written to cure.

This row is the recipe and the receipts. Everything below re-derives; nothing is a prediction.

## The one-sentence result

Runs **30714372486** (red) and **30714465001** (green), on PR
[#8928](https://github.com/FRIKKern/barkpark/pull/8928) — closed UNMERGED, branch deleted —
prove **AGGREGATOR PROPAGATION** (a failing `needs` entry turns `Console gate` red, and its
revert turns it green) and prove **NOTHING about merge-blocking**: re-derived at build time,
`gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks.checks'`
returns exactly `[{"app_id":15368,"context":"Elixir gate"},{"app_id":15368,"context":"PR
references an active task"}]` and `gh api repos/FRIKKern/barkpark/rules/branches/main`
returns `[]` — `Console gate` is on neither list, and there is no second door.

`.github/required-checks.json` is deliberately NOT touched here and no row is filed for its
drift: `cch-w11-s1-flip-behind-a-generator-that-cannot-lose` owns it and the fix is a live PUT.

## The mutation — exact, and it is the whole edit

`cloud/priv/static/app.css:3042`, inside the GR109 block that must sit *below* the
`.attention-row` base or lose the cascade at equal specificity:

    -  .attention-row { flex-direction: column; align-items: flex-start; }
    +  .attention-row { flex-direction: column; }

`git show --stat 35908a194` reads `1 file changed, 1 insertion(+), 1 deletion(-)` — **not**
`1 deletion, 0 insertions`, because that physical line packs two declarations, so removing
one rewrites the line rather than deleting it. The diff above is the proof that nothing else
moved.

Local control on the same machine, minutes apart:

    node cloud/priv/static/__preview__/overflow-guard.mjs; echo rc=$?
    # origin/main  → rc=0, "OVERFLOW GUARD PASS — GR108…, GR109…, GR115…, W12…, W13…, W15…, W18…"
    # mutated      → rc=1, "OVERFLOW GUARD FAIL — 2 finding(s) in: GR109-attention-row-dead-rule"

Do **not** mutate band-A instead (`CHIP_BAND_A_MAX_SHORTFALL = 9` can absorb a mutation into
a green), and do not re-use the W15-fleet leg (its local mutation was already held).

## Receipts — RED, run 30714372486, head 35908a194

Job conclusions from `gh run view 30714372486 --json jobs`:

| job | id | conclusion |
|---|---|---|
| Overflow guard (rendered) | 91407361675 | **failure** |
| Console gate | 91407442356 | **failure** |
| Dispatch (console paths) / path-escape / cssom-parity / console-unit / tier-floor | — | success |

Three verbatim log lines, in the order that makes the red trustworthy:

    dispatcher outputs: console='true'
    OVERFLOW GUARD FAIL — 8 finding(s) in: GR109-attention-row-dead-rule, GR115-bpconsole-dead-rule
      FAIL    overflow-guard: failure
    ##[error]Console gate: at least one upstream job is not in the allow-set (see above). This is the required context; it is RED on purpose.

The two GR109 findings are the predicted, locally-reproduced ones:

    ✗ @768 align-items is "center", expected "flex-start" — the authored rule is cascade-dead (row stacks but stays centred)
    ✗ @768 .attention-acts left 448.8 != .attention-main left 275 — buttons are centred, not left-aligned

**No pixel literal is pinned.** `448.8` is what this runner measured; macOS/Inter prints
`448.78`. The durable expectations are the finding COUNT for GR109 (2), the leg NAME, and the
first failing line's *shape* — a computed-keyword comparison, which is font-independent.

### The count diverged, and the divergence is measured, not waved away

The brief predicted `2 finding(s) in: GR109-attention-row-dead-rule`. The runner printed 8,
across two legs. The other six are all `GR115-bpconsole-dead-rule` reporting **UA-default**
computed values — `max-height` `none`, `font-size` `16px` / `13.3333px`, caret `transform`
`none`, collapsed-toggle `border-bottom` `outset/2px` — i.e. that scenario's stylesheet did
not apply *at all*. A one-declaration edit inside `@media (max-width: 768px) { .attention-row
{ … } }` cannot produce that. The GREEN control below, on byte-identical content, the same
branch and the same `ubuntu-latest`, reported GR115 clean — so this is an **intermittent**,
not an ubuntu-persistent red and not mutation collateral. It has its own filed row rather
than being buried in this one.

## Receipts — GREEN, run 30714465001, head d62ff0791 (the revert)

Same PR, same two job names, `gh run view 30714465001 --json jobs`:

| job | id | conclusion |
|---|---|---|
| Overflow guard (rendered) | 91407602434 | **success** |
| Console gate | 91407666714 | **success** |

    dispatcher outputs: console='true'
      ok      overflow-guard: success
    Console gate: every upstream job either succeeded or was legitimately not dispatched.
    OVERFLOW GUARD PASS — GR108-tablet-topbar-overflow, GR109-attention-row-dead-rule, GR115-bpconsole-dead-rule, W12-narrow-viewport-truth, W13-detail-route-band, W15-fleet-row-text-bounded, W18-overview-card-pill measured fixed in a real browser

At the branch tip, `git diff origin/main -- cloud/priv/static/app.css` produced **0 bytes** —
the revert is byte-for-byte.

The green run also exercised the dispatcher's revert-pair arm, and that annotation is worth
keeping: *"the changed-file set is EMPTY (a revert pair or a branch-sync PR nets to nothing
…). Dispatching console=true and running the WHOLE harness rather than skipping it — a skip
here would green a required context nothing measured."* The control is a real measurement.

## Two traps that would have made the whole proof worthless

**The false-green trap (D217).** `overflow-guard` is gated
`if: needs.changes.outputs.console == 'true'`, and the aggregator's `decide` ACCEPTS a skip
against a gate value of exactly `'false'`. A mutation outside the console dispatch set
therefore skips the job and greens BOTH contexts while looking exactly like a healthy run.
So the red evidence must quote `Console gate`'s own `dispatcher outputs: console='true'`
line — which is why it is the first line quoted above, on both runs. `app.css` is inside
`CONSOLE_PATHS`; confirm with
`printf 'cloud/priv/static/app.css\n' | bash scripts/console-path-escape-check.sh --match console`.

**The concurrency trap.** `concurrency.group: console-harness-${{ github.ref }}` with
`cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}` — **true on any PR branch**.
Push the revert only after `gh run watch <red-run-id>` reports the run CONCLUDED, or
`failure` silently becomes `cancelled` and the evidence evaporates. (`cancelled` is also in
`decide`'s failing arm, so the aggregator would still be red — for the wrong reason, and the
run id would prove nothing.) Here `gh run watch 30714372486 --exit-status` exited 1 with
`X Console gate in 2s (ID 91407442356)` before the revert went out.

## The recipe, to re-run this on any future guard leg

    git worktree add <dir> -b <proof-branch> origin/main
    # push 1: the single deliberate regression; git show --stat must be one file
    gh pr create --draft            # body carries `Task: <slice-id>`
    gh run watch <red-run-id>       # WAIT for CONCLUDED — do not race the revert
    git revert --no-edit HEAD && git push
    gh run watch <green-run-id>
    gh pr close <n> --delete-branch # NEVER merge this PR

Then ship only the docs-only ledger row. `gh pr view 8928 --json state,mergeCommit` reads
`{"state":"CLOSED","mergeCommit":null}` — the mutation exists nowhere on `main`.
