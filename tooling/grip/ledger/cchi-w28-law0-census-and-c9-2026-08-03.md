# Re-derivation recipes — cloud-console-hardening wave 28 VERIFY (2026-08-03)

Law 0 provenance, the D306 census split, the re-parent triage, and the C9 /
`cuePaints` settlement — every number below re-derived, none inherited.

**PROVENANCE (D319), all three facts:**

| fact | value |
|---|---|
| UTC stamp (predicate's own `read at`) | `2026-08-03T13:22:31.636Z` |
| tree sha | `3cf1bda5661b6a119d017d1c8582fd2a93f356ed` |
| commit sha (NOT the tree) | `dfdc31db96b85b66515a1cba3f92a9e9bd81b09b` |
| resolved repo root (`pwd -P`) | `/private/var/folders/hb/18wmml0n5495w28s_1z_8flh0000gn/T/tmp.slUHo0pOda/law0` |

The Strategize note quoted `dfdc31db9…` as the **tree**. It is the **commit**.
The tree is `3cf1bda56…`. Corrected here.

Charter on `origin/main` runs to **D326** — next free number is **D327**, not D251.

## R1 — the seal predicate, UNPIPED, from a clean detached worktree

`rc` is captured off the predicate itself, never off a pipe (`... | tail` would
report tail's rc).

```bash
cd /Volumes/SATECHI/github/barkpark
git rev-parse origin/main origin/main^{tree}
W=$(mktemp -d) && git worktree add -q --detach "$W/law0" origin/main
cd "$W/law0" && pwd -P && git status --porcelain      # must print NOTHING
out=$(node cloud/priv/static/__preview__/seal-predicate.mjs \
        --epic cloud-console-hardening-epic \
        --successor cch-instruments-epic 2>&1); rc=$?
echo "UNPIPED rc=$rc"
printf '%s\n' "$out" | grep -E 'VERDICT-TOKEN|roster|residue'
```

Observed (`rc=1`):

```
roster: 288 children  {"done":194,"open":59,"cancelled":34,"considering":1}
CLAUSE (a) forwarding — residue 60 (live 59, considering 1)
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=57 considering=1 \
  successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live stubbed=0 waived=0
```

Cleanup: `git worktree remove "$W/law0" && rm -rf "$W"`.

## R2 — the D306 split: RE-PARENTED 55, CLOSED 5, ORPHANS 57 (three integers)

Baseline is wave 27's predicate census **343** `{done 189, open 119, cancelled
34, considering 1}`. Today's same-instrument census is **288** `{194, 59, 34,
1}`.

| quantity | value | derivation |
|---|---|---|
| RE-PARENTED out of the epic | **55** | roster 343 − 288 |
| CLOSED in place | **5** | done 194 − 189 |
| ORPHANS today | **57** | a separate reading, not a movement count |

Closes exactly: `119 − 55 − 5 = 59` open ✓ · `189 + 5 = 194` done ✓ ·
cancelled `34 → 34` ✓ · considering `1 → 1` ✓. The identity only closes if all
55 re-parented rows were `open`, which it does.

The wish's sentence "57 rows were re-parented by hand" conflates the **orphan
reading** with the **re-parent movement**. They are 57 and 55. This is the exact
indistinguishability D306 exists to forbid.

## R3 — `orphans` SILENTLY INCLUDES the disclosed `considering` row

`seal-predicate.mjs` (origin/main) partitions `residue = [...live,
...considering]` and then buckets **that** list:

```
:856  const residue = [...live, ...considering];
:865  const orphans = [], gatedLive = [], fwd = [];
:866  for (const c of residue) {
:867    if (PERMANENT_HUMAN_GATES[c._id]) gatedLive.push(c._id);
:868    else if (forwarded.has(c._id)) fwd.push(c._id);
:869    else orphans.push(c._id);
```

So `cloud-console-operator-audit-log` is printed on BOTH lines — as
`considering (disclosed) : 1` and inside `UNNAMED RESIDUE (orphans) : 57`.
Arithmetic: 59 open − 3 gates = **56** open orphans; +1 considering = 57.

```bash
# reproduce the 56 vs 57
curl -sG "$BP_SERVER/v1/data/query/production/task" \
  --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
  --data-urlencode 'limit=500' -H "Authorization: Bearer $BP_TOKEN" |
python3 -c 'import json,sys
d=json.load(sys.stdin)["result"]["documents"]
g={"cch-hg-compose-network-recreation","gr-ops-platform-admin-emails","gr-backlog-qr-live-scan-proof"}
print(len([x for x in d if x["lifecycle_status"]=="open" and x["_id"] not in g]))'   # -> 56
```

A row cannot be both disclosed and unnamed. Decide should either exclude
`considering` from the orphan bucket or stop calling it disclosed.

## R4 — the predicate is BLIND to 3 draft-twin children (288 vs 291)

`bp task get cloud-console-hardening-epic` reports **291** children; the
predicate's published query reports **288**. The gap is three `drafts.` rows —
two of them **open**:

```
drafts.cch-w22-s2-site-row-name-and-host-bounded          open
drafts.cch-w26-bl-deploy-row-siblings-unwrapped           open
drafts.task-c64f2a37d7f97bd8                              cancelled
```

`fetchRoster` reads `/v1/data/query/production/task` (published only,
seal-predicate.mjs:356). A draft edit sitting on a `done` published row is
invisible to Law 0. `drafts.cch-w26-bl-deploy-row-siblings-unwrapped` matters
directly: the published twin reads DONE and the Strategize note leans on that.

```bash
# the diff that produced the three
python3 -c '...'   # set-difference of bp children[].doc_id against query _id
```

## R5 — re-parent triage BY BODY against the successor charter's own predicate

Rule (verbatim, `.claude/workflows/bp-cloud-console-instruments-charter.md:94-105`):
a row belongs to `cch-instruments-epic` when **all four** hold — (1) names an
instrument-claim/measurement divergence, (2) invisible to a person, fixing it
changes no pixel and no response byte, (3) inside the surface fence, (4) carries
a measurement. Tiebreak: *"When it is genuinely both, it goes to the parent."*

Applied to all 56 open orphans by BODY (not title). **7 confirmed movers**, not 12:

| row | why it moves |
|---|---|
| `cch-bl-floor-blind-to-readme-and-uncalled` | required-checks floor machinery; mutation-proven blind |
| `cch-w11-bl-required-checks-live-suite-unrun-at-four` | test-rig coverage gap, in fence |
| `cch-w12-bl-independent-review-owed-wave-12` | "epic-cycle's own method / filing discipline", verbatim in fence |
| `cch-w12-s5-successor-split-and-letterbox-fence` | seal predicate + ledger tooling |
| `cch-w22-s7-cruelty-ledger-effective-caps-and-classes` | `__preview__` harness |
| `gr-bl-gr108-fix-overdetermined` | fix-attribution defect; changes no pixel |
| `task-4f363dc65ac43203` | names a MISSING guard; adding it changes no served byte |

**Explicitly kept (registration-class, charter-named, out of fence):**
`cch-w11-s1-flip-behind-a-generator-that-cannot-lose`,
`cch-w11-residue-security-gate-registration-policy`.

**Kept by the tiebreak (genuinely both):** `gr-backlog-tablet-width-audit`,
`gr-backlog-css-check-missing-classes`, `cch-w24-bl-word-break-alias-has-no-ruling`.

**Naming trap — `cchi-w22-bl-shared-modal-card-min-content-floor` STAYS.** It
carries the successor's `cchi-` prefix but its body describes `.modal-root`
becoming *"a silent horizontal scroller at phone widths"* — person-visible,
clause 2 fails. A title-keyed move would have mis-filed it. This is why the
triage is BY BODY.

### BOUNDARY RULING — `cch-w24-bl-word-break-alias-remaining-seven` STAYS

Ruled here rather than drifting a ninth wave. Three of four clauses fail:

- **(1) FAILS** — the body names a *stylesheet population* (7 `word-break:
  break-word` sites) and a triage duty, not an instrument divergence. The
  nearest instrument claim is carried by its sibling
  `cch-w24-bl-word-break-alias-has-no-ruling`, not by this row.
- **(2) FAILS** — converting any of the seven moves min-content by
  construction; s4's own measurement (box `92.25 → 129.22px`) is the proof the
  class moves pixels.
- **(3) FAILS** — `cloud/priv/static/app.css` is console surface, not
  instrument surface.
- **(4) passes** — it does carry a derived count (`grep -c 'word-break:'` → 15
  lines, 3 prose, 12 live declarations, 5 `break-all`).

All four are required. **Verdict: stays under `cloud-console-hardening-epic`.**

## R6 — C9 / `cuePaints`: D325's kill reason is REFUTED, and the successor row does NOT carry a C9-equivalent

```bash
cd /Volumes/SATECHI/github/barkpark
git grep -n cuePaints origin/main -- cloud/
git cat-file -e origin/main:cloud/priv/static/__preview__/app.css   # rc 128, absent
git ls-tree -r --name-only origin/main | grep 'app\.css$'           # cloud/priv/static/app.css
```

Output:

```
origin/main:cloud/priv/static/__preview__/overflow-guard.mjs:4129:  const cuePaints = n.te === "ellipsis" && (n.ws === "nowrap" || n.ws === "pre");
origin/main:cloud/priv/static/__preview__/overflow-guard.mjs:4130:  if (n.sw > n.cw && !cuePaints) {
fatal: path 'cloud/priv/static/__preview__/app.css' does not exist in 'origin/main'
cloud/priv/static/app.css
```

The successor row `cchi-w27-bl-w22s7-residue-derived-caps-and-refusals`
(id `bc10f9b4-2fb0-47ee-a261-a9e30b874c87`, 0/9 met) carries **9** criteria, and
its **criterion index 7** reads verbatim:

> *"C9 IS DELIBERATELY NOT CARRIED and this row does not reinstate it: its
> central symbol `cuePaints` has ZERO occurrences anywhere under `cloud/`, and
> its second anchor `cloud/priv/static/__preview__/app.css` does not exist."*

**Both halves fail on origin/main:**

1. `cuePaints` has **2** occurrences under `cloud/` (4129, 4130) — not zero.
2. The anchor path is a **typo**, not an absent file: `app.css` lives at
   `cloud/priv/static/app.css`, and the companion comment C9 cites has merely
   **drifted** from `:2110-2117` to **`:2411-2420`**, directly above
   `.set-row-name` (`:2421`) — the very selector the `cuePaints` leg polices.

**Answer to the assignment's question: NO. The successor carries no
C9-equivalent** — its only mention of C9 is the refusal above.

**The predicate is substantively wrong, not merely orphaned.** CSS requires
`overflow` ≠ `visible` for `text-overflow: ellipsis` to render. The predicate
tests only `te` and `ws`:

```
:4083  rec.name={sw:…,cw:…,ws:cs.whiteSpace,te:cs.textOverflow,…}     <- no overflow collected
:4129  const cuePaints = n.te === "ellipsis" && (n.ws === "nowrap" || n.ws === "pre");
```

A node with `ellipsis` + `nowrap` + `overflow: visible` scores `cuePaints =
true` and is **waved through** while nothing paints and the text spills — a
green by construction, the standing test's own failure shape. The model arm is
**four hundred lines below, in the same file**: `:4534` collects
`ov:cs.overflow` alongside `ow/ws/te`. app.css:3482 also names the
`overflow: visible` + ellipsis pairing explicitly.

Decide must either re-scope the successor row to carry C9 with the corrected
anchors, or state on the record why a live wrong predicate stays in a shipped
instrument.

## R7 — stamp mechanics for `cch-w22-s7`, verified before use

`cch-w22-s7-cruelty-ledger-effective-caps-and-classes`
(`224cf8c2-6616-4388-aa9e-d79f79460cf7`) is `lifecycle_status: open`,
`criteria_progress {met: 0, total: 16}`, **`claim: null`**.

> Note: the wish states D325 "split and stamped five criteria". **Zero stamps
> are present on either row** (0/16 and 0/9). Treat the five as unpaid.

`bp task stamp --help` (verified verbatim, not assumed):

```
usage: barkpark task stamp <doc_id> <worker_id> <observed_epoch>
  --criterion N     ZERO-BASED index — the first criterion is 0, NOT 1
  --met             requires non-empty --evidence AND --criterion-text
  --criterion-text  REQUIRED with --met; exact stored wording. Missing -> 409
                    criterion_text_required; mismatched -> 409 criteria_mismatch
  --miss --note     records an honest attempt on the attempts list; met never flips
  Holder-only + the same epoch fence as close (a lapsed claim can't stamp).
```

Therefore, in order:

```bash
bp task claim cch-w22-s7-cruelty-ledger-effective-caps-and-classes <worker>   # row is UNCLAIMED; returns the epoch
bp task stamp <doc_id> <worker> <epoch> --criterion <0-based> \
  --miss --note "n/a — split to cchi-w27-bl-w22s7-residue-derived-caps-and-refusals"
```

`--miss --note` is the only honest recording for an "n/a — split" criterion:
`--met` would assert work nobody did, and `--miss` flips nothing.
