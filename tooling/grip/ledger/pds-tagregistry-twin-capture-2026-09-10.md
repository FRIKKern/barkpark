# pds-bl-tagregistry-guard-no-rung — the armed draft twin, captured and REFUTED (2026-09-10)

Lane `cli-r4-w10`, for row `pds-bl-armed-draft-twin-tagregistry`. Everything below was RUN
against `https://guerrilla.barkpark.cloud` on 2026-09-10, or reads `origin/main` at
`b2e2b80ce`. The JSON companion is `pds-tagregistry-twin-capture-2026-09-10.json`.

Shell prelude used by every live row:

    TOK=$(jq -r .token ~/.config/barkpark/config.json); B=https://guerrilla.barkpark.cloud

## THE HEADLINE: the twin is GONE, and it was discarded on 2026-09-04

The filing (2026-07-30) describes a live pair. It is no longer one. The published row's own
revision history names the discard:

| when (UTC) | action | status | rev |
|---|---|---|---|
| 2026-07-30T19:29:55.593636Z | create | draft | (pre-rev era) |
| **2026-09-04T11:08:58.748770Z** | **discardDraft** | draft | **491e53bbdb1ac59f0591ccc61f6d9cef** |
| 2026-09-04T11:11:13.054997Z | create | draft | 2237b42d4426afeec8b995ec803fbd5f |
| 2026-09-04T11:11:16.399823Z | publish | published | f45f96e9c0ac474a838a865985b06ebb |

`491e53bb…` is the exact draft rev the filing named. The twin was discarded, and a fresh
draft was minted and published three minutes later.

| # | Claim | Command |
|---|---|---|
| 1 | `drafts.pds-bl-tagregistry-guard-no-rung` does NOT exist: HTTP body `{"error":{"code":"not_found"…}}` | `curl -s "$B/v1/data/doc/production/task/drafts.pds-bl-tagregistry-guard-no-rung" -H "Authorization: Bearer $TOK"` |
| 2 | **CONTROL for row 1** — the `drafts.` address space IS readable today, so row 1 is an ABSENCE and not an unreadable lens: this returns 200 with `_draft: true` | `curl -s "$B/v1/data/doc/production/task/drafts.pds-bl-go-tests-not-required" -H "Authorization: Bearer $TOK"` |
| 3 | **SECOND CONTROL** — a paged `perspective=raw` walk of `type:task` returns 9,356 ids, **762** of them `drafts.`-prefixed, and NOT ONE of them is the named twin | `for off in $(seq 0 1000 9000); do curl -s "$B/v1/data/query/production/task?perspective=raw&limit=1000&offset=$off" -H "Authorization: Bearer $TOK" \| python3 -c 'import sys,json;[print(x["_id"]) for x in json.load(sys.stdin,strict=False)["result"]["documents"]]'; done \| grep -c '^drafts\.'` |
| 4 | The published half survives intact: rev `f45f96e9c0ac474a838a865985b06ebb`, `lifecycle done`, criteria `[met, met, unmet, met]`, evidence **1119 UTF-8 bytes** across criteria 0/1/3 (611 + 377 + 131) | `curl -s "$B/v1/data/doc/production/task/pds-bl-tagregistry-guard-no-rung" -H "Authorization: Bearer $TOK"` |
| 5 | The L1 witness was NOT destroyed by the discard — the revision store still serves the whole discarded draft: `lifecycle open`, 0/4 met, 0 bytes of evidence, `parent_id task-2ac1f95237c4a8e5` | `env -u BARKPARK_TOKEN bp doc revision 42ac8ac0-46e7-4af7-b1e7-7f0059f25322 -o json` |
| 6 | The discarded draft did NOT carry a null claim — it carried an EXPIRED one (`worker: null`, `previous_worker: epic-builder-…`, `expired_at 2026-07-30T20:14:00.973320Z`, epoch 2), which is still `!=` the published closed claim | row 5's output, `.revision.content.claim` |

### CORRECTIONS to the filing, dated 2026-09-10

Each of these was true-as-of the filing or simply mis-stated; none is a reword of the
captured criterion, and the original wording is left standing on the row.

* **"1113 bytes of stamped evidence"** is a CHARACTER count wearing a byte label.
  609 + 373 + 131 = 1113 characters; the same three strings are 611 + 377 + 131 = **1119
  UTF-8 bytes**. The two non-ASCII strings are criteria 0 and 1 (em dashes). The evidence
  text is byte-for-byte the same today as at the filing — the delta is the ruler, not the row.
* **"It is the ONLY `drafts.pds*` row store-wide"** is false today and was already false two
  days after the filing: `draft-twin-live-probe-2026-08-01.md` row 12 names three pds twins.
  Today the raw walk shows **16** `drafts.pds*` ids, 14 of which are true twins.
* **"`bp doc discard-draft` … also destroys the L1 witness, hence capture first"** is false.
  Row 5 above reads the entire discarded draft back out of the revision store, weeks after
  the discard. Capture-first is still good practice; it is not a one-way door.
* **The published rev named in the filing (`43e6314f…`) is stale** — the row was re-published
  on 2026-09-04 at `f45f96e9…`.
* **The row's own `disposition_reason` (2026-08-22) says the drafts lens is `unread`** because
  "the source answered perspective:published for a perspective=drafts read". That is no longer
  true: `scripts/pds-ledger-census.sh` prints `(DRAFT-CAPABLE: the source answered
  perspective:drafts)` on a 2026-09-10 run, and rows 2 and 3 above read `drafts.` documents
  directly. The lens is honoured; the twin is genuinely absent.

## The claim-divergent refusal, EXECUTED (not derived)

The filing's severity verdict was DERIVED from `stale_claim?/2`
(`api/lib/barkpark/content/lifecycle.ex:908`). It is executed here on a throwaway probe row,
`w10-forked-draft-lifecycle-fence-probe`, shaped exactly like the target — published half
`done` with a CLOSED claim and one stamped, evidence-bearing criterion; draft half `open`,
claim-less, 0 met.

Building the probe pair required a detour that is itself a finding: **neither ordinary write
path can mint an armed twin any more.** `bp doc patch task <id>` on a published row now
creates a draft and publishes it in the same breath (history: `create draft` then `publish`,
150 ms apart), and a raw `POST /v1/data/mutate/production` `patch` naming the bare published
id now returns `_draft: false` on the BARE id — the WRONG-ROW fork recorded in
`draft-twin-live-probe-2026-08-01.md` rows 2–4 is REPAIRED. The probe's draft half had to be
minted directly with `createOrReplace` on `_id: "drafts.<id>"`.

| arm | draft state vs published | `bp doc publish task w10-forked-draft-lifecycle-fence-probe --yes` |
|---|---|---|
| **A** | claim absent, criteria weaker | REFUSED — `claim: ["stale draft: the published row carries claim state (worker \"cli-r4-w10\", epoch 1) this draft does not — publishing would obliterate it. …"]` |
| **B** | claim copied VERBATIM, criteria still weaker | REFUSED — `acceptance_criteria: ["stale draft: publishing this draft would clear the \`met: true\` flag for acceptance criterion 0 … the published row holds that proof and this draft does not. …"]` |
| **D** (positive control) | draft discarded, re-derived via `bp doc patch`, then published | **ACCEPTED** — published rev advances, `lifecycle done`, criteria `[True, False]` preserved |

Arm A is the target's shape, and it is the refusal the filing predicted. Arm B proves the two
fences are ORDERED and independent — clearing the claim fence does not clear the criteria
fence, so the published evidence is protected twice over. Arm D proves the door is not simply
always saying no. After arms A and B the published half was byte-unchanged at rev
`ac953f25f92f62a408f9fc1b26d25834`, criteria `[True, False]`.

A third arm, C, tried to `createOrReplace` a `drafts.` doc carrying `lifecycle_status: done`
and was refused by a DIFFERENT wall at the mutate layer (HTTP 422): *"cannot be moved to the
terminal state \"done\" through /v1/data/mutate without a revision precondition — a blind
patch closes a task with no claim, no worker and no epoch."*

## Rail vs census: which lens owns the pds-* row count

Both measured 2026-09-10, minutes apart.

| lens | number | command |
|---|---|---|
| epic rail, one level | `child_count 623`, 623 children listed, **2 of them `drafts.`-prefixed** | `env -u BARKPARK_TOKEN bp task get task-2ac1f95237c4a8e5 -o json` |
| census, transitive closure | **738** descendants over `parent_id` (max depth 2), 214 live, 176 `open` | `bash scripts/pds-ledger-census.sh` |

**The census closure is authoritative; the rail is not.** The rail is `.children`, and
`scripts/pds-ledger-census.sh` documents in its own header why that lens cannot be a count:
it is ONE LEVEL DEEP, so every grandchild hanging under a `done`/`cancelled` parent is
invisible to it (measured there at 181 of 287, a ~63% score), and its `--lens children`
mode exists ONLY so the selftest can watch the closure's fixpoint assertion catch it. The
gap is live today: 623 against 738 — a 115-row spread between the two lenses, measured
minutes apart against the same root.

**Why 205 was the wrong number.** 205 is the rail's `child_count` as read on 2026-07-30
(`pds-w26-evidence-audit-failclosed-2026-07-30.md` §R1). It fails as a "pds-* row count"
three separate ways, and its own source says so:

1. **It is one level deep.** Same defect as above, at a smaller board.
2. **Eight of the 205 are not `pds-`-prefixed at all** — `pdf-provider-neutral-fleet-tooling`,
   `task-015fb9866bc2cc59`, `task-018754b481a901df`, `task-1e76a21eb8a17d43`,
   `task-5c4f2673778d5ff0`, `task-6fc6820c62e9b646`, `task-a0e37c21f73f8e26`,
   `task-fff1116564723b60`. So 205 is a CHILDREN count, never a pds-* count.
3. **One of the 205 was the `drafts.`-prefixed twin itself** — the rail counted an edit
   shadow of a row it was already counting. §R2 of that same file measures it:
   `204/205 _draft:false`, the exception being `drafts.pds-bl-tagregistry-guard-no-rung`.

The census names that third failure mode explicitly and refuses to make it: its blind-spot
report classes such rows as **PHANTOMS** — "`open` draft whose PUBLISHED twin is TERMINAL —
an EDIT SHADOW, never hidden work. Adding these to the denominator OVERCOUNTS." Ten such
phantoms exist on the 2026-09-10 board.

## The two `drafts.` rail children that REMAIN — do not discard them

The rail still lists two `drafts.`-prefixed child ids, and neither is this row's twin:

    drafts.task-85d64913a19c0d70                  lifecycle cancelled, no published twin (404)
    drafts.pds-bl-wrongpath-arm-blind-to-wrong-id lifecycle cancelled, no published twin (404)

    for i in drafts.task-85d64913a19c0d70 task-85d64913a19c0d70 \
             drafts.pds-bl-wrongpath-arm-blind-to-wrong-id pds-bl-wrongpath-arm-blind-to-wrong-id; do
      curl -s "$B/v1/data/doc/production/task/$i" -H "Authorization: Bearer $TOK"; done

Both are DRAFT-ONLY. `bp doc discard-draft` keeps the published version and there is no
published version, so on these two the verb is not a cleanup — it is a deletion. They carry
no stamped evidence (0 bytes), but they are rows, not shadows, and removing them is a
disposition decision and not hygiene. Left standing, named here.

## CLI defects observed in passing (not filed by this lane)

* `bp task stamp --help` instructs, in prose, that the criterion wording "must ride a FILE:
  `--criterion-text-file <path>`" — and the installed binary answers
  `bp: unknown flag --criterion-text-file for task stamp`. Only `--criterion-text` is
  registered. The help text and the parser disagree.
* `bp task create --publish --help` promises "a row that cannot clear the wall is refused
  BEFORE anything is created, so a failed `--publish` never leaves a draft behind". On a
  near-duplicate refusal the CLI printed BOTH "The refused draft … was discarded, so this
  publish left nothing behind" AND "the row exists as a DRAFT ONLY … publish the draft you
  already have: `bp doc publish task <id> --yes`". The draft was in fact gone; the second
  half of the message is a remediation for a state that does not exist, and following it
  returns 404.
