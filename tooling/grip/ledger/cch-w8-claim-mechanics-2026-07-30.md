# cch-w8 — M0 claim mechanics on an EXPIRED claim (the untested rung of D86)

Run live on guerrilla 2026-07-30 against a REAL epic row
(`cch-bl-mockjs-revoke-stateless`, criterion idx 7, PR #6697). Every line is a
re-derivation recipe, not a conclusion. The row was paid end to end; nothing was
rehearsed on a scratch twin.

## The shape under test

`cch-w7-ledger-write-rehearsal-2026-07-28.md` rehearsed the RELEASED shape
(`claim.worker == null`, `released_by` set) and left the EXPIRED shape
(`expired_at` + `previous_worker`, `worker: null`) explicitly **untested**.
All six wave-7 merge-gate rows carry the EXPIRED shape, not the released one.

    bp task get <id> -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'],json.dumps(d.get('claim')))"
    # -> open {'met': 7, 'total': 8} {"epoch": 6, "expired_at": "2026-07-28T15:02:08Z",
    #         "previous_worker": "epic-builder-…", "worker": null}

## RESULT: claim SUCCEEDS. No holder_override needed anywhere in M0.

    bp task claim cch-bl-mockjs-revoke-stateless lead-wave8 -o json
    # -> "claim":{"epoch":7,"worker":"lead-wave8",...}, lifecycle_status: in_progress

Consequences the brief must carry:

* The claim BUMPS the epoch (6 -> 7) and the returned epoch is the only one that
  works. A brief that hardcodes "close on epoch 7" without claiming first is
  guessing; claim, parse `.doc.claim.epoch`, use that.
* The claim flips `lifecycle_status` open -> **in_progress**. A sweep that claims
  N rows and dies mid-flight leaves them in_progress, not open — the census must
  count `open||in_progress||considering`, and a resumed sweep must not re-claim.

## Stamp then close, on the returned epoch — no digest 409

    bp task stamp <id> lead-wave8 7 --criterion 7 --met \
      --evidence "PR #6697 merged as 99e3ee8… (merge-base --is-ancestor -> ANCESTOR-OK)" \
      --criterion-text 'PR merged to main (LEAD closes this criterion, pasting the merge SHA from `gh pr view <n> --json mergeCommit`).'
    # -> criteria_progress 8/8, rev 50b60b03…, status published

The `--criterion-text` must be BYTE-verbatim (backticks included) or the server
409s `criteria_mismatch`. Single-quote it in the shell; the text contains
backticks that a double-quoted heredoc would execute.

A stamp mutates `acceptance_criteria`, which is one of the four fields in
`claim.work_field_digests` — but the following close on the SAME epoch did
**not** 409 `doc_changed_since_claim`. Stamping under your own claim re-bases
the fence. `observed_rev` was never needed.

## The one-call atomic form behaves identically

    bp task close <id> lead-wave8 7 done "<reason>" \
      --set 'criteria:=[{"index":7,"met":true,"criterion":"<verbatim>","evidence":"<sha>"}]'
    # -> lifecycle_status done, criteria_progress 8/8, status published,
    #    content.close_reason set, claim.closed_by lead-wave8

Same end state as stamp-then-close; one round trip instead of two. Prefer it for
the sweep (fewer requests — see rate limiting below). Re-read PUBLISHED after
every write; a printed rev is not persistence:

    bp task get <id> -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'],d['status'])"

## GitHub mirror re-syncs on close — it is NOT frozen

    gh issue view 5373 -R FRIKKern/barkpark --json state,updatedAt,labels

* pre-close: OPEN, `status:in_progress`, updated 2026-07-28T15:03:17Z
* after the CLAIM (14:03:42Z): issue updated 14:04:21Z, new label `worker:lead-wave8`
* after the CLOSE (14:04:24Z): **CLOSED at 14:05:07Z** — ~43s convergence,
  `content.github.synced_rev` advanced to the close rev `b65e298d…`.

The D86 draft-first freeze does not fire here because no `bp doc patch` ever
touched the row. stage/close/move only — that law holds and is why the mirror moved.

## Rate limiting is a real sweep hazard

A poll loop at ~1 bp call / 20s took two `429 rate_limited` on
`GET /v1/capabilities` (the manifest fetch every bp invocation performs) inside
two minutes, on a shared host with sibling waves running. A 55-row sweep of
2 calls/row must retry on 429 (`Retry-After: 1`) and must not treat a manifest
429 as a row-level failure — the failure surfaces as an empty stdout and a
JSONDecodeError downstream, which is indistinguishable from a missing row.
Consider `BARKPARK_MANIFEST=<file>` to remove the per-call manifest fetch.

## Still untested

* Whether `bp task claim` also succeeds on the RELEASED (`released_by`) shape —
  the five rows D86 lists. Only the EXPIRED shape was exercised here.
* Whether a foreign close WITHOUT a claim still refuses on the expired shape
  (D86 says yes for the released shape). Moot if the brief claims first.
