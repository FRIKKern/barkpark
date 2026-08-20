# PDS wave 24 — movement-2 census recipe, PROVEN end to end (2026-07-30)

Verifier assignment `census-recipe-proof`. Probe row `task-bf05436d1539548a`
("w24 census probe") was created, published, patched three times, read across four
routes on a timed loop, then DELETED and the deletion confirmed by post-condition read
(HTTP 404 on every route). Server: `https://guerrilla.barkpark.cloud`, dataset `production`.

## Verdict

The strategist's proof standard ("re-read the row and count the field you claimed to
write") is SAFE — but only with the recipe below. Run naively it produces a number that
looks honest and is wrong, by three independent mechanisms, each measured here.

## Measured facts

### 1. Bare patch → published read is a FALSE NEGATIVE for 30–40 s (confirmed)

`bp doc patch task <id> --set …` writes ONLY `drafts.<id>`. Sentinel `probeB-140848`:

    t=+1.3s   published_doc="probeA-140650"  tasks_api="ERR:rate_limited"  raw_drafts.id="probeB-140848"
    t=+6.1s   published_doc="probeA-140650"  tasks_api="probeA-140650"     raw_drafts.id="probeB-140848"
    t=+15.3s  published_doc="probeA-140650"  tasks_api="probeA-140650"     raw_drafts.id="probeB-140848"
    t=+30.3s  published_doc="probeA-140650"  tasks_api=ERR:rate_limited    raw_drafts.id="probeB-140848"
    t=+40.2s  published_doc="probeB-140848"  tasks_api=ERR:rate_limited    raw_drafts.id=ERR:not_found
    t=+75.3s  published_doc="probeB-140848"  tasks_api="probeB-140848"     raw_drafts.id=ERR:not_found

The window is NOT a constant: an earlier round (`probeA`) collapsed at ~5.5 s, this one
between 30.3 s and 40.2 s. **A fixed `sleep N` before re-reading is therefore not a fix.**

### 2. Patch THEN publish → read-your-write on EVERY route inside ~1.6 s (confirmed)

Sentinel `probeC-141047`; `bp doc patch` + `bp doc publish` together took 1.44 s wall:

    t=+1.6s   published_doc="probeC-141047"  tasks_api(bp task get)="probeC-141047"
    t=+5.6s   published_doc="probeC-141047"  tasks_api(bp task get)="probeC-141047"
    t=+14.0s  published_doc="probeC-141047"  tasks_api(bp task get)="probeC-141047"

**PUBLISH AFTER EVERY PATCH. This is the whole fix for hazard 1.**

### 3. Raw read on `drafts.<id>` is immediate — and 404s once the draft collapses

Correct at t=+1.3 s, `ERR:not_found` from t=+40.2 s. It is a good *write* confirmation
and a **useless census primitive**: rows with no pending draft (i.e. almost all of them)
return `not_found`, which a careless script scores as "no reason".

### 4. `--limit 5000` SILENTLY CAPS AT 1000 — a 54% undercount that greens

One un-paginated read (`--limit 5000`, server returned 1000 of `total: 3791`) built a
closure of **127** descendants. Paginated at `--limit 1000 --offset 0,1000,2000,3000`
(3791 unique rows) the same code built **284** — the digest's figure, exactly:

    LEVEL-1 children: 178
    TRANSITIVE descendants: 284
    closure lifecycle_status: {'done': 91, 'cancelled': 26, 'open': 135, 'considering': 31, 'blocked': 1}
    LIVE: 167

### 5. The two APIs use DIFFERENT error envelopes

`/v1/data/*` → `{"ok":false,"error":{"code":"not_found"}}`
`/v1/tasks/*` → `{"ok":false,"reason":"not_found","message":"task not found"}`

A census that tests `error.code` scores every `/v1/tasks` failure as a success. This bit
this very verification twice (once as a phantom "propagation lag", once as a phantom
"delete did not take"). **Test the HTTP status code, not an envelope key.**

### 6. Rate limiting is real: HTTP 429 at ~1 req/1.5 s

Even `bp --help`-class calls re-fetch `/v1/capabilities` and count against it. Pin the
manifest once (`curl … /v1/capabilities > w24-manifest.json; export BARKPARK_MANIFEST=…`)
and prefer ONE bulk `doc query` over N per-row `task get`s.

## Census figures at instant 2026-07-30T14:14Z (re-derive, never quote)

    disposition over 167 LIVE, case-exact: {'OPEN': 56, 'open': 47, None: 37, 'parked': 27}
    live rows with a non-empty disposition_reason: 130
    DISTINCT reason md5s: 112          <-- 18 short of 130, so NOT yet done
    largest duplicate hash: 4f556ba7 on 19 rows   <-- the boilerplate; corroborates census-rederive
    live rows carrying a REACTIVATE trigger: 27

Movement 2's done-predicate — `distinct == non_empty AND off_vocabulary == 0` — currently
reads **112 != 130**, so it is honestly red on the hash half. The off-vocabulary half
depends on which case the wave ratifies as canonical, and the four counts above sum to
exactly 167, so both branches are arithmetic on measured values:

- canonical `{open, parked, closed}` → off-vocabulary = `OPEN` 56 + absent 37 = **93 of 167**
- canonical `{OPEN, PARKED, CLOSED}` → off-vocabulary = `open` 47 + absent 37 = **84 of 167**

Either way it is red, and **movement 2 must ratify one case before it can compute this
number at all** — an unratified vocabulary makes the done-predicate unevaluable, not zero.

## THE RECIPE movement 2 must commit under scripts/pds-*

    # 0. Pin the manifest once — otherwise every bp call re-fetches /v1/capabilities and 429s.
    OUT="$(mktemp -d)/pds-w24-census-$$"; mkdir -p "$OUT"   # UNIQUE path, never a shared dir
    curl -sS -H "Authorization: Bearer $BP_TOKEN" "$BP/v1/capabilities" > "$OUT/manifest.json"
    export BARKPARK_MANIFEST="$OUT/manifest.json"

    # 1. Read the WHOLE task table, PAGINATED. Never --limit >1000; assert you got `total`.
    off=0; while :; do
      bp doc query task --fields '_id,parent_id,lifecycle_status,disposition,disposition_reason' \
         --limit 1000 --offset $off -o json > "$OUT/page-$off.json"
      n=$(jq '.documents|length' "$OUT/page-$off.json"); [ "$n" -eq 0 ] && break
      off=$((off+1000)); sleep 2
    done
    # HARD ASSERT: unique ids loaded == .total from page 0, else ABORT. A short read must
    # never be allowed to produce a census number.

    # 2. Build the closure CLIENT-SIDE from parent_id — one level is not the board.
    #    ASSERT descendants == 284 (or the wave's re-derived figure) or FAIL LOUD.
    #    A lens regression to 178 (level-1) or 127 (short read) must break the gate.

    # 3. Iterate an EXPLICIT id list written to "$OUT/ids.txt". NEVER a directory glob:
    #    tooling/grip/ledger/ holds 222 files from six concurrent epics (cch-*, astro-*, …);
    #    a glob there reads other waves' work as if it were yours. Same for scratchpads —
    #    derive every path from "$OUT", and never open a file you did not create this run.

    # 4. For every disposition WRITE:  bp doc patch … --yes  &&  bp doc publish … --yes
    #    then re-read via the bulk query in step 1 and COUNT the field. Never a bare patch.

    # 5. Score errors on HTTP STATUS, not on an envelope key (the two APIs differ, §5).

## Residue this run created and did not clean

`bp task create` auto-synced the probe to GitHub as **FRIKKern/barkpark issue 8092**
(`content.github.issue: 8092`, state `synced`). Deleting the Barkpark row does NOT close
the issue. Any wave that files throwaway probe rows leaves GitHub litter — either close
8092 by hand or file probes with the GitHub sync suppressed.

## Incidental findings for the wave

- `bp task create --publish` FAILS the publish wall twice over: `label_spine` (needs a
  non-trivial description AND 1–12 weighted tags) then `unknown_tag` (tags must already be
  registered `type:tag` docs). A row filed by the naive documented invocation is left as an
  UNPUBLISHED DRAFT and `bp doc get task <id>` then returns `not_found` — the operator sees
  "created task-…" and a 404 on the same row. That is an exit-code-only success claim on
  the ledger the epic is audited on.
- `bp task create --help` already documents the draft/published asymmetry verbatim, so the
  fix for hazard 1 is known to the CLI and simply not enforced anywhere.

## Environment hazard that ended this run

The host filled its disk mid-verification: every subsequent `Bash` call died with
`ENOSPC … /private/tmp/claude-501/…/tasks/<id>.output` — the harness could not write a
command's stdout, so no command could run, including `df`. Two checks were left
unrun: whether `scripts/` already holds a census/triage script (movement 2 may be
building a second one), and a final `git status --porcelain`. **This machine cannot host
movement 2's paginated census** — four 1000-row pages of task JSON is ~10 MB of scratch
per run, and the disk had no room for a few KB of command output. Free space before Build,
or the census dies halfway and leaves a partial count that looks like a finished one.
