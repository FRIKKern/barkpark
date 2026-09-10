# pe-w2 · hollow corpus repair — re-survey, repair, ratchet (2026-09-10)

Task `pe-w2-bl-hollow-corpus-repair`. Every row below is a literal command that
re-derives the fact from the RUNNING guerrilla server or from this checkout.
Supersedes the population statement in the task row, which is a 2026-08-17
snapshot — see §0.

    BASE=https://guerrilla.barkpark.cloud

## 0 · WHAT THE FILING GOT WRONG

The row says the ten text-keyed papers "still carry" the defect and that
`cch-w57-bl-eleven-papers-render-200-with-prose-the-reader-drops` is UNCLAIMED.
Neither held on 2026-09-10:

    env -u BARKPARK_TOKEN bp task get cch-w57-bl-eleven-papers-render-200-with-prose-the-reader-drops -o json

All FOUR of w57's criteria are `met: true`, stamped 2026-09-02, and its fourth
evidence line reads: *"Whole-corpus sweep 2026-09-02 … scanned 1050 | value-keyed
174527 | text-keyed 0 | papers 0."* The eleven text-keyed papers were repaired
server-side between the 2026-08-17 filing and 2026-09-02 by that lane. This task's
text-keyed half was therefore ALREADY DONE when it was routed; the re-survey below
is the confirmation, not the repair.

What the filing got RIGHT and nobody had cleared: `heggemsnes-act` as the last
malformed-items paper. That was still live and still dropping prose behind a 200
(§2). And the re-survey found a THIRTEENTH paper the filing never named,
`epic-paper-beauty-reference-wave-2026-07-31`, carrying the same class in the
INLINE-ARRAY shape rather than the bare-string one (§3).

## 1 · the re-survey: text-keyed leaves corpus-wide = 0

    env -u BARKPARK_TOKEN bp doc query paper --all --fields _id,blocks -o json \
      | grep '^{' > /tmp/corpus.json      # 1048 published papers
    bash scripts/paper-dialect-ratchet.sh --source /tmp/corpus.json --expect-zero

    /tmp/corpus.json: text_keyed 0 | malformed_items 0 | value_keyed 177540
    OK.

`--limit 1000` is a TRAP here: `bp` fills the page exactly and prints
`result page filled your --limit of 1000 exactly; more may be available` on
stdout ahead of the JSON. `--all` plus `grep '^{'` is the correct recipe — the
first run of this survey read 1000 of 1048 papers and did not know it.

**REAL-SHAPE CONTROL for the zero.** A corpus-wide zero is exactly what a blind
walker reports, so the same walker was run over a PRE-repair revision fetched
from the same server:

    env -u BARKPARK_TOKEN bp doc history paper deploy-reliability-wave-4-2026-08-06 -o json
    env -u BARKPARK_TOKEN bp doc revision 3a62ccc7-0f43-4073-afef-4ea6477befb2 -o json
    # -> text-keyed leaves in that 2026-08-06 revision: 283

283 on the old bytes, 0 on the current bytes, one walker. The zero is a
measurement. The ratchet carries this control permanently as the
`min_value_keyed` floor (§4).

**The read path does not launder the count.** Every caller of the normalizer is
write-side — `content/writer.ex:743,1646`, `content/lifecycle.ex:145`,
`papers/block_ops.ex:279,703,1304,2967`, `papers/proposals.ex:139`,
`papers/backfill_block_ids.ex:186`, `papers/pre_gate_register.ex:184`. No
serializer, controller or query path calls `normalize_render_shapes/1`, so
`bp doc query` returns the STORED dialect:

    git grep -n normalize_render_shapes -- api/lib

## 2 · heggemsnes-act repaired through the #11616 chokepoint

Before — 5 `notes` items stored as BARE STRINGS in block `hga-remedies`, page
answering 200 with the prose gone:

    curl -s -o /tmp/hga.html -w '%{http_code}\n' $BASE/papers/heggemsnes-act   # 200
    grep -c 'his original description restored verbatim' /tmp/hga.html         # 0

Repair = re-write the SAME blocks through `/v1/data/mutate`; the chokepoint's
`normalize_widget_item/1` does the conversion (`%{"text" => s}`), so no block
content was authored, edited or deleted by hand.

    env -u BARKPARK_TOKEN bp doc mutate --file hga-mutate.json --yes -o json
    # mutations: [{createOrReplace: {_id,_type,title,style,description,tags,main_tag,blocks}},
    #             {publish: {id: "heggemsnes-act", type: "paper"}}]

After:

    grep -c 'his original description restored verbatim' /tmp/hga-after.html   # 1

| slug | rev BEFORE | rev AFTER | prose sentinel |
|---|---|---|---|
| heggemsnes-act | `423948eec0744622639eafad7827e8b6` | `3ead12a03aaca4ae264630ba0ac36fd1` | "PR #11556: his original description restored verbatim from the edit history…" 0 → 1 |

Reversible by rev: the pre-repair bytes are the revision behind
`423948ee…` (`bp doc history paper heggemsnes-act`).

## 3 · the thirteenth paper the filing never named

`epic-paper-beauty-reference-wave-2026-07-31`, block `local-suite-note`: two
`notes` items stored as INLINE ARRAYS, not bare strings. The 2026-08-17 survey
walk tested `isinstance(item, str)` and so could not see them; the ratchet's
walk tests `not isinstance(item, dict)` and does — *an enumeration is a
snapshot, a predicate is a rule.*

    grep -c 'A broad local run executed 13,189 tests' /tmp/epbr-before.html      # 0
    grep -c 'shared line-keyed baseline is already stale' /tmp/epbr-before.html  # 0
    # ... same createOrReplace + publish through the chokepoint ...
    grep -c 'A broad local run executed 13,189 tests' /tmp/epbr-after.html       # 1
    grep -c 'shared line-keyed baseline is already stale' /tmp/epbr-after.html   # 1

| slug | rev BEFORE | rev AFTER | prose sentinel |
|---|---|---|---|
| epic-paper-beauty-reference-wave-2026-07-31 | `37b504ce3a5b0a5196f79df834d55a27` | `46b65f551ea74b061f68e033c0c332ce` | "The isolated CI suite is the merge authority." 0 → 1 |

## 3b · the per-slug PROSE SENTINEL sweep (13/13)

A 200 is not evidence. Each slug is grepped for sentinels drawn from its OWN
stored prose, sampled with a STRIDE across the whole block list **plus every
notes/cards item and pipeline node** — the widget items are forced in because
that is where this defect hides:

    python3 sentinel-sweep.py corpus.json <slug>…

    cloud-console-hardening-wave-57-2026-08-09    HTTP 200  sentinels  24/24
    deploy-reliability-wave-2026-08-06            HTTP 200  sentinels  24/24
    deploy-reliability-wave-4-2026-08-06          HTTP 200  sentinels  24/24
    deploy-truth-wave-1-2026-08-05                HTTP 200  sentinels  24/24
    deploy-truth-wave-2-2026-08-06                HTTP 200  sentinels  24/24
    cloud-console-hardening-wave-22-2026-08-02    HTTP 200  sentinels  24/24
    cloud-console-hardening-wave-8-2026-07-30     HTTP 200  sentinels  82/82
    perfect-plan-readiness-ledger                 HTTP 200  sentinels  24/24
    perfect-plan-research-wave-2026-07-12         HTTP 200  sentinels 106/106
    playground-tenancy-cost                       HTTP 200  sentinels  24/24
    workspace-bundle-keystone                     HTTP 200  sentinels  24/24
    heggemsnes-act                                HTTP 200  sentinels  24/24
    epic-paper-beauty-reference-wave-2026-07-31   HTTP 200  sentinels  24/24
    TOTAL 452/452

**A FIRST SWEEP THAT PASSED WAS WRONG.** The initial version took the FIRST 20
sentences of each paper and printed `heggemsnes-act 20/20` — GREEN, against the
saved PRE-repair page, on a paper whose defect was live. The first 20 sentences
all came from healthy prose blocks; the 5 dead rows sat further down. That green
was *a green with no subject*. The stride + forced-widget-items sweep, re-run
against the same saved pre-repair pages, is the control:

    python3 sentinel-sweep.py corpus-before.json \
      heggemsnes-act=hga-before.html \
      epic-paper-beauty-reference-wave-2026-07-31=epbr-before.html

    heggemsnes-act                                sentinels 20/24  (4 MISS)
    epic-paper-beauty-reference-wave-2026-07-31   sentinels 20/24  (4 MISS)
    TOTAL 40/48   rc=1

Same instrument, same slugs, pre-repair bytes → RED. Post-repair → 452/452.

## 4 · the ratchet: `scripts/paper-dialect-ratchet.sh`

Counts, per corpus, three numbers: text-keyed inline leaves, malformed widget
items (notes/cards items and pipeline nodes that are not maps), and — as a
NON-VACUITY FLOOR — canonical value-keyed leaves. Baseline
`scripts/.paper-dialect-baseline`. Growth reds (1); a shrink never reds;
anything that makes the gate unable to MEASURE refuses (2) rather than greening.

    rig-fixtures 0 5 840
    twin         0 0 167
    go-testdata  0 0 2

`rig-fixtures` holds 5 on purpose: `tooling/paper-excellence/rig/fixtures/
heggemsnes-act.json` is the frozen PRE-repair specimen of the paper §2 repaired.
A ban would force that specimen to be laundered; a shrink-only count lets it
stand and still makes a NEW dirty payload a visible second-file bump.

**MUTATION PROOF, both directions** (`--selftest`, 18 arms, all green):

| arm | plant | verdict |
|---|---|---|
| B | one text-keyed leaf at top level | `text-keyed inline leaves GREW — c: 0 -> 1` (rc 1) |
| B2 | remove that leaf, same tree | `no dialect count grew` (rc 0) |
| C | one bare-string `notes` item | `malformed widget items GREW — c: 0 -> 1` (rc 1) |
| C2 | one bare-string `pipeline` node | same metric, rc 1 |
| D | a text-keyed leaf NESTED in `section.blocks` | rc 1 — the walk descends |
| E | a leaf carrying BOTH keys | rc 0 — canonical, not a defect |
| F | baseline above reality | rc 0 with a shrink note |
| G | corpus emptied of canonical leaves | REFUSE 2, `non-vacuity floor breached` |
| H–N | missing source, unparsable JSON, absent baseline, unpinned source, stale row, non-integer, empty table | REFUSE 2 each |
| O | floor ONE above reality | REFUSE 2 — arm A's green is non-vacuous |
| P/Q | `--source --expect-zero` clean / dirty | rc 0 / rc 1 `BYPASS` |

Arm O exists because the FIRST version of this script shipped a real bug: the
baseline parser printed only three fields of a four-field row, so `want_vk` was
empty, `[ "$vk" -lt "" ]` errored, and the floor was never evaluated. Arms A/B/F
all passed anyway. G and O caught it. A ratchet with a dead floor is exactly the
guard this defect class already defeated once.

## 5 · gate wiring — REPORTED, NOT APPLIED

`.github/workflows/*` is outside this task's fence, so the two hunks below are
for the lead to route. They mirror the silencer ratchet's wiring verbatim
(steps `s32`/`s33` at doc-gates.yml:1294-1308).

**(a) trigger paths.** `scripts/**` does not match a dotfile, so
`scripts/.paper-dialect-baseline` — the file the whole gate compares against —
matches NOTHING today. Add it next to `scripts/.silencer-counts` in BOTH paths
blocks (doc-gates.yml:230 and :520). The script itself rides `scripts/**`; the
measured corpora ride no glob, so name them too:

```yaml
      - "scripts/.paper-dialect-baseline"
      - "tooling/paper-excellence/rig/fixtures/**"
      - "tooling/paper-excellence/twin/**"
```

**(b) the steps**, appended after the LAST step of that job — `repo-papers
snapshot freshness (fails this job)`, id `s35`. **`s34`/`s35` are already
taken**; the next free ids are `s36`/`s37`:

```yaml
      # PAPER DIALECT RATCHET (pe-w2-bl-hollow-corpus-repair). A text-keyed
      # inline leaf and a bare-string notes/cards item both render NOTHING
      # behind a 200. The write chokepoint (BlockOps.normalize_render_shapes/1,
      # #11616) rescues both — but only for payloads that reach persistence
      # THROUGH it. A payload committed to this repo as a fixture never does.
      # This step pins a count per in-repo corpus and reds when one GROWS,
      # with a non-vacuity floor that REFUSES (2) rather than greening when the
      # walker stops matching. Same S4 blast radius as the step above: visible
      # on the PR, cannot block a merge.
      - name: Paper dialect ratchet self-test (tripwire)
        id: s36
        continue-on-error: true  # main-red breaker: the Decide step below owns the verdict
        if: ${{ !cancelled() }}
        run: |
          if [ -z "${BREAKER_CAPTURE_ARMED:-}" ] && [ -f "$GITHUB_WORKSPACE/scripts/breaker-capture.sh" ]; then exec bash "$GITHUB_WORKSPACE/scripts/breaker-capture.sh" "$0"; fi  # main-red breaker: capture this step's error block
          bash scripts/paper-dialect-ratchet.sh --selftest

      - name: Paper dialect ratchet (fails this job)
        id: s37
        continue-on-error: true  # main-red breaker: the Decide step below owns the verdict
        if: ${{ !cancelled() }}
        run: |
          if [ -z "${BREAKER_CAPTURE_ARMED:-}" ] && [ -f "$GITHUB_WORKSPACE/scripts/breaker-capture.sh" ]; then exec bash "$GITHUB_WORKSPACE/scripts/breaker-capture.sh" "$0"; fi  # main-red breaker: capture this step's error block
          bash scripts/paper-dialect-ratchet.sh
```

**(c) the Decide map — REQUIRED, not optional.** Every step in that job carries
`continue-on-error: true`; the verdict is owned by the `Decide (main-red
breaker…)` step at doc-gates.yml:1354, which reads `STEP_NAMES`, a JSON object
mapping step id → step name. A step id absent from that map is a step that runs,
reds, and is never read — the exact `continue-on-error` vacuous green this repo
has been bitten by. Add to the `STEP_NAMES` value:

```
\"s36\": \"Paper dialect ratchet self-test (tripwire)\", \"s37\": \"Paper dialect ratchet (fails this job)\"
```

The names must match the `- name:` lines byte-for-byte.

**Honest limit.** CI cannot reach guerrilla (no token in the workflow), so the
gate that RUNS on every PR measures the in-repo payload corpora only. The LIVE
corpus sweep is `--source <dump> --expect-zero`, run by hand or from a session
that holds the token; §1 is today's run.

## 6 · what was NOT done

* No `.github/workflows/*` edit (fence). §5 is the hunk to route.
* No `api/lib/**` edit — no read-side defect blocked the repair; the chokepoint
  did all the conversion.
* No Elixir test run: this change adds no Elixir code.
* The eleven papers of §3b other than the two in §2/§3 were NOT re-written by
  this task. They were already clean on arrival (repaired by the cch-w57 lane
  2026-09-02); their rows in §3b are verification, not repair.

## 7 · appendix — the sentinel sweep, re-derivable

`sentinel-sweep.py` is a run artefact, not a shipped gate (the shipped
instrument is `scripts/paper-dialect-ratchet.sh`). Its whole rule, so §3b can be
rebuilt from this file alone:

1. From the paper's stored `blocks`, collect (a) every `notes`/`cards` item and
   `pipeline` node's text — bare string, `text`/`label`/`title`/`detail` of a
   map, or the flattened inline text of an array — and (b) every
   `{"type":"text","value":…}` plus every `text`/`label`/`title`/`caption`
   string, anywhere in the tree.
2. Split both on sentence boundaries; keep 40–180 char sentences with no `<`.
3. Sentinels = ALL of (a) — the widget items are where this defect hides — then
   (b) sampled with a stride so the picks span the WHOLE block list, to at least
   24 total. **Never the first N sentences**: that is what made the first sweep
   green on a live defect.
4. `curl $BASE/papers/<slug>`, strip tags, unescape entities, collapse
   whitespace, and require every sentinel to be a substring. The HTTP code is
   printed and is never the verdict.

Run artefacts (this session's scratch, not durable):
`orchestrate/tmp/lead-studio/studio-r4-w11/{sentinel-sweep.py,hga-before.json,
hga-mutate.json,epbr-before.json,epbr-mutate.json,corpus-final2.json}`.
