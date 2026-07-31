# cch-w12 — `bp task create` health, and the seal predicate's DEAD-LETTERBOX hole (2026-07-31)

Two questions, both driven, neither read.

1. **Is `bp task create` healthy right now?** YES. D105's "wholesale CREATE outage"
   does not reproduce; the charter's own wave-9 narrative already refutes it
   (`D105 IS REFUTED … It is INTERMITTENT`). First attempt succeeded, no retry.
   The full create→publish path also works, but ONLY with the wall's tag shape
   `[{tag,strength,rationale}]` — the `[{name,weight}]` shape is accepted by the
   DRAFT write and then 422s `label_spine` at publish.
2. **Does `seal-predicate.mjs` accept a DONE task as a legal successor?** YES —
   and it is not hypothetical. `gr-p5r5-successor-seal` is `lifecycle_status: done`,
   `status: published`, and `parent_id: cloud-console-hardening-epic` (i.e. a CHILD
   of the epic it is offered as successor to). The predicate resolved it and printed
   it as the forwarding address. `resolveTask` checks `_type` and `status`; it never
   reads `lifecycle_status`. D89's dead letterbox, unfenced, plus a second unfenced
   shape R4 does not catch: a successor inside the epic's own subtree.

Third finding, unasked: **the "92 live" census is inflated by 4.** The predicate's
published-only roster reads 184 children / 88 open + 1 considering; `bp task get`
reads 190 / 92 open. The 6-row delta is 2 draft TWINS of published rows
(double-counted), 3 draft-ONLY rows (invisible to every board and to the predicate,
one of them `open`), and 1 scratch probe. D105 already ruled that a census must
count `drafts.*` as duplicates, never as rows.

## Re-derivation

    # --- 0. the primary checkout is 162 commits behind; run from an origin/main tree
    git -C /Volumes/SATECHI/github/barkpark log --oneline HEAD..origin/main | wc -l
    git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | wc -l   # 900
    wc -l < cloud/priv/static/__preview__/seal-predicate.mjs                        # 572, no --ladder-only

    # --- 1. create health (one attempt, no retry)
    bp task create --title 'scratch: wave-12 create health probe' \
      --set parent_id=cloud-console-hardening-epic \
      --set 'tags:=[{"name":"testing","weight":5}]' \
      --description '…' -o json --yes
    # -> {"draft":"drafts.task-…","id":"task-…","lifecycle_status":"open","status":"draft"}
    bp doc get task drafts.<id> --perspective raw -o json      # reads back byte-for-byte

    # --- 2. create+publish path (the op the successor ruling is gated on)
    bp task create --title '…' --description '…' \
      --set 'tags:=[{"tag":"testing","strength":90,"rationale":"…"}]' --publish -o json --yes
    # NOTE: `bp task publish` DOES NOT EXIST (verbs: ls ready prime events get claim
    # close release stamp next move stage pulse). Republish is `bp doc publish task drafts.<id>`.

    # --- 3. the successor hole, live
    node cloud/priv/static/__preview__/seal-predicate.mjs --successor gr-p5r5-successor-seal
    # -> exit 1, "successor: gr-p5r5-successor-seal", forwarded 0, orphans 86
    #    NO UNRESOLVABLE-SUCCESSOR refusal — the done row was accepted.
    bp task get gr-p5r5-successor-seal -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['status'],d['parent_id'])"
    # -> done published cloud-console-hardening-epic

    # --- 4. the honest read that claims nothing
    node cloud/priv/static/__preview__/seal-predicate.mjs --ladder-only
    # -> exit 0, VERDICT-TOKEN: … LADDER-ONLY b-rungs=rung1:2,rung2:4,rung3:0
    #    b-clean=6/6 a=NOT-READ c=NOT-READ

    # --- 5. the census delta
    curl -sG "$BP_SERVER/v1/data/query/production/task" \
      --data-urlencode "filter[parent_id]=cloud-console-hardening-epic" \
      --data-urlencode "limit=500" -H "Authorization: Bearer $BP_TOKEN"     # 184 docs
    bp task get cloud-console-hardening-epic -o json                        # 190 children
    # delta: drafts.gr-backlog-css-brace-detector (TWIN of a published row),
    #        drafts.cch-w11-s1-flip-behind-a-generator-that-cannot-lose (TWIN),
    #        drafts.cch-bl-floor-blind-to-readme-and-uncalled (draft-only, OPEN, invisible),
    #        drafts.cch-bl-floor-is-blind-and-uncalled (draft-only, cancelled),
    #        drafts.cch-bl-required-checks-floor-blind-uncalled (draft-only, cancelled).

## Anchors (origin/main @ ac80af23e)

- `cloud/priv/static/__preview__/seal-predicate.mjs` `resolveTask` — three checks,
  none of them `lifecycle_status`; R3 (`UNRESOLVABLE-SUCCESSOR`) therefore passes a
  done/cancelled task. R4 only catches `SUCCESSOR === EPIC`, not a successor whose
  `parent_id` IS the epic.
- Charter D89 (the tombstoned-address ruling), D105 (create outage + the
  `drafts.*`-are-not-rows census rule), and the wave-9 narrative line that already
  refutes D105.

## Side effects of this probe, all cleaned

Creating a task mirrors it to a real GitHub issue **while it is still an unpublished
draft**, and `bp doc delete` on the draft ORPHANS that issue (it stays OPEN with no
ledger row behind it) — D86's "cancel, never delete" hazard reaching the GitHub
bridge. Issues 8425/8426/8427 were closed by hand; the published probe row
`task-9c13814e00c9e45f` was claimed and closed `cancelled` (epoch 2); the two drafts
were deleted. Epic roster restored to 184 published / 89 residue.
