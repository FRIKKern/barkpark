# Deploy-reliability ledger repair — re-derivation recipes (wave 6 verify)

Epic GOAL: `task-fb4fb869490b4213`. All commands run 2026-08-06 against the configured bp server.
No mutations were made by this pass; every row below is a READ that Decide can re-run before it writes.

## 0. The read recipe the survey handed forward is BROKEN

    bp doc get task drafts.dr-w5-s4-agent-binary-reaches-the-fleet -o json   # -> not_found (WRONG)
    bp task get  drafts.dr-w5-s4-agent-binary-reaches-the-fleet -o json      # -> the draft (RIGHT)
    bp doc query task --filter '_id*=agent-binary' --count -o json           # -> total 0 (_id filters are dead)

`bp doc get` cannot address a `drafts.`-prefixed id, and `--filter` on `_id` silently returns 0 rows for a
document that provably exists. Any census built on either is vacuous. The only reliable enumeration of the
epic ledger is the parent rail:

    bp task get task-fb4fb869490b4213 -o json      # child_count 98, children[] carries lifecycle + criteria_progress

## 1. The phantom holds NOTHING the published twin lacks (survey premise inverted)

    bp task get drafts.dr-w5-s4-agent-binary-reaches-the-fleet -o json   # .doc.content
    bp doc  get task dr-w5-s4-agent-binary-reaches-the-fleet -o json

Field-by-field diff of the two contents:

| field | phantom | published |
|---|---|---|
| acceptance_criteria (8 rows, texts identical) | met 2/8 (idx 2,3) | met 4/8 (idx 0,1,2,3) |
| criteria idx 2,3 evidence | 461 / 1108 bytes | byte-identical |
| criteria idx 0,1 evidence | empty | 1873 / 1368 bytes |
| title | null | present |
| claim | null | epoch 5 |
| brief, description, files, tags, parent_id, priority, wave_paper, assignee | identical | identical |

The published row is a strict SUPERSET. COPY-BEFORE-DISCARD IS A NO-OP; discard destroys nothing.

## 2. Thirteen stale-open rows, each mapped by PR BODY (not title)

    for n in 9613 9614 9615 9616 9617 9727 9729 9730 9731 9732 9733 9734 9827; do \
      gh pr view $n --json number,state,mergedAt -q '[.number,.state,.mergedAt]|@tsv'; \
      gh pr view $n --json body -q .body | grep -oE 'dr-[a-z0-9-]+' | sort -u | head -3; done

| PR | merged | primary task (still `open`) | criteria |
|---|---|---|---|
| 9613 | 2026-08-05 | dr-w1-s1-graph-visibility-bound-readmit | 6/8 |
| 9614 | 2026-08-05 | dr-w1-s2-fleet-ledger-classifier | 9/10 |
| 9615 | 2026-08-05 | dr-w1-s3-409-deferral-index-rekey | 8/9 |
| 9616 | 2026-08-05 | dr-w1-s4-webhook-doctype-filter | 5/8 |
| 9617 | 2026-08-05 | dr-w1-s5-swallow-records-upstream-status | 7/10 |
| 9727 | 2026-08-06 | dr-w2-s1-recorder-build-id-keyed-log | 8/10 |
| 9729 | 2026-08-06 | dr-w2-s2-provision-rmrf-wedge | 6/7 |
| 9730 | 2026-08-06 | dr-w2-s3-poll-grace-5xx-and-named-refusal | 7/8 |
| 9731 | 2026-08-06 | dr-w2-s4-scrub-knows-our-own-token | 6/8 |
| 9732 | 2026-08-06 | dr-w2-s5-cli-status-stops-lying | 8/9 |
| 9733 | 2026-08-06 | dr-w2-s6-engine-one-extractor-health-slow-vs-broken | 6/9 |
| 9734 | 2026-08-06 | dr-w2-s7-scoped-search-permission-clamp | 7/10 |
| 9827 | 2026-08-06 | dr-w3-s5-door-refuses-box-at-capacity | 11/12 |

9617's mapping was title-only in the survey; PR 9617 body line 31 reads
`Task: dr-w1-s5-swallow-records-upstream-status`, so the mapping is now PR-derived.

## 3. The honest denominator is 71

    bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys,collections; \
      print(collections.Counter(x['lifecycle_status'] for x in json.load(sys.stdin)['children']))"
    # Counter({'open': 86, 'done': 11, 'cancelled': 1})   total 98

    98 rows
    -11 done, -1 cancelled          -> 86 open
    -13 open-but-its-PR-is-merged   -> 73
    - 1 drafts.* phantom double-count -> 72
    - 1 dr-w3-s7 superseded by dr-w5-s1 -> 71   <-- the honest open count

Supersession proof: dr-w3-s7's own description begins "THIS SLICE DOES NOT BUILD THIS RUN"; its `files`
list is a superset of dr-w5-s1's seven, and dr-w5-s1 stands at 11/12 with PR #9887 (OPEN/MERGEABLE/BLOCKED).

## 4. The "PR body states X" criteria — THREE dead, TWO satisfied-but-unstamped

    gh pr view 9731 --json body -q .body | grep -inE "flip-risk|second review|independent"
    gh pr view 9733 --json body -q .body | grep -inE "tier|two halves|dr-w2-s2"
    gh pr view 9727 --json body -q .body | grep -inE "tee|oom|memorymax"
    gh pr view 9617 --json body -q .body | grep -inE "search-starter-smoke|astro-finder-drift"

| row | criterion | verdict |
|---|---|---|
| dr-w2-s4 idx 5 | PR body flags HIGH-FLIP-RISK + asks for a second reviewer | **SATISFIED** — 9731 body line 3 says exactly this. Stamp it. |
| dr-w2-s6 idx 3 | PR body states no fifth tier, with per-tier counts | **SATISFIED** — 9733 body line 7 prints tier1 0, tier2 exactly 1, tier3 strictly worse, "No fifth tier". Stamp it. |
| dr-w2-s6 idx 6 | PR body states dr-w2-s2 + this slice are two halves of one repair | **DEAD** — grep for halves/half/rmrf/wedge/provision/9729/s2 over the whole 18-line body returns nothing. |
| dr-w2-s1 idx 6 | PR body reports whether the tee'd FILE survived an OOM kill | **DEAD BY SUCCESSION** — 9727 body line 20 records an honest `--miss` and files `dr-w2-s1-followup-oom-tee-flush` (in the rail, open 0/2). |
| dr-w1-s5 idx 7 | the three advisory template workflows named and pasted green on the PR | **DEAD** — no occurrence of search-starter-smoke / astro-finder-drift / astro-search-finder-test in 9617's body. |

A merged PR's body is still editable, so "dead" here means the pre-merge disclosure the criterion existed to
force cannot be re-created — not that the text is immutable. Retro-editing a merged body to green a criterion
would be exactly the vacuous pass the charter forbids.
