# Felix W26 — D164 ledger-close worksheet (verifier: d164-ledger-worksheet)

Re-derived against origin/main `6ea916104c` on 2026-08-17. Every row below was read live via
`bp task get <id> -o json`. **Close CAS requires the CURRENT claim** — every PAID row carries either
a null claim or a LAPSED claim (`worker:null`, `expired_at` in the past), so the recipe is:
re-claim → mark the EXACT last-criterion text met → close with the fresh worker+epoch → read back.
The 409 class (bp-writes-silently-don't-land) trips on any templated/approximate criterion text, so
the verbatim `LAST_CRIT` strings below are load-bearing.

## Rerun

    git show origin/main:.claude/workflows/bp-felix-pristine-charter.md | sed -n '2314,2345p'
    bp task get <id> -o json | jq '.doc | {lifecycle_status,status,claim,acceptance_criteria:(.content.acceptance_criteria//.acceptance_criteria)}'

## PAID — 19 open rows to close (each: id | life | claim | paying commit | verbatim last criterion)

1. felix-w23-s1-drift-migration | open | lapsed epoch7 worker=null | #6616 27352d8c13 | "PR merged to main (LEAD closes on merge evidence)"
2. felix-w23-s5-blobstore-migration | open | claim=null | #7553 5a0f4abfa4 | "PR merged to main (LEAD closes on merge evidence)"
3. felix-w24-s1-blobstore-fifteen | open | lapsed epoch7 worker=null | #7553 5a0f4abfa4 | "MERGE-GATED (lead closes): the PR is merged to origin/main with the Elixir gate green"
4. felix-w23-bl-fenced-sixteen | open | claim=null | #9411 92f91f0433 | "PR merged to main (LEAD closes on merge evidence)"
5. felix-w24-s6-fenced-sixteen | open | claim=null | #9411 92f91f0433 | "MERGE-GATED (lead closes): the PR is merged to origin/main with the Elixir gate green"
6. felix-w23-s2-staleness-ratchet | open | lapsed epoch6 worker=null | #7555 c66008ae2b + #11427 4ca033f502 | "PR merged to main (LEAD closes on merge evidence)"
7. felix-w23-bl-staleness-blocking-flip | open | claim=null | #7555 + #11427 | "PR merged to main (LEAD closes on merge evidence)"
8. felix-w24-s3-baseline-prune-and-flip | open | lapsed epoch5 worker=null | #7555 + #11427 | "PR merged to main (LEAD closes on merge evidence)"
9. felix-w24-bl-staleness-script-header-stale | open | lapsed epoch3 worker=null | #7555 | "PR merged to main (LEAD closes on merge evidence)"
10. felix-w24-bl-staleness-line-anchor | open | claim=null | #7555 + #11427 | "PR merged to main (LEAD closes on merge evidence)"
11. felix-w23-bl-overlap-unbound-annotation | open | claim=null | #6412 c69cc0b1ee + #7556 | "PR merged to main (LEAD closes on merge evidence)"
12. felix-w24-s4-annotation-binding-ratchet | open | lapsed epoch7 worker=null | #7556 2f9f25dd93 | "Committed on a loop-epic branch and merged to main (LEAD closes this criterion)"
13. felix-w24-bl-config-hash-line-consistency | open | claim=null | #7556 | "The check runs in the advisory sobelow job (it needs the BEAM) and does not slow or destabilise the BEAM-free blocking job"  ← NOT a merge-gate string; this exact technical text is the last criterion
14. felix-w24-bl-multiclause-annotation-review | open | claim=null | #7556 | "Any clause found to carry a risky call gets its own annotation with its own verdict, and felix-w24-s4's MULTI-CLAUSE predicate is confirmed to red before and green after"  ← NOT a merge-gate string
15. felix-w23-s4-fresh-guard-selftest | open | lapsed epoch5 worker=null | --selftest shipped on main | "PR merged to main (LEAD closes on merge evidence)"
16. felix-w23-s3-amend-d75 | open | lapsed epoch6 worker=null | #7557 f91bf276b9 | "PR merged to main (LEAD closes on merge evidence)"
17. felix-w24-s5-merge-gates-dead-premise | open | lapsed epoch3 worker=null | #7557 f91bf276b9 | "MERGE-GATED (lead closes): the PR is merged to origin/main"
18. felix-w24-s2-router-csp-fix | open | lapsed epoch4 worker=null | #7554 458ce20113 | "MERGE-GATED (lead closes): the PR is merged to origin/main with the Elixir gate green"  ← CAVEAT: Headers vs CSRF; 5 router.ex Config.CSRF rows remain baselined — read the row body before closing
19. task-felix-w20-fk-census-tripwire | open | lapsed epoch6 worker=null | #5920 851e06703c | "MERGE GATE (lead closes): PR merged with cloud.yml green (compile --warnings-as-errors + format + mix test job); merge commit ancestor of origin/main."

## NO-OP rows

20. felix-w24-s7-continue-on-error-flip | open | claim=null | close superseded, zero builders | "MERGE-GATED (lead closes): the PR is merged to origin/main with the Elixir gate green"  ← close as no-op per D164
21. felix-w23-bl-continue-on-error-flip | ALREADY cancelled | claim worker=felix-verify-w26 epoch1 | already actioned THIS wave by sibling felix-verify-w26 — NO further action

## Already closed / do-not-close

- task-felix-phantom-media-atomicity (D7 phantom-media, #2955 38c68c81fd) | lifecycle=DONE | claim lead-opus epoch8 — already closed, no action.
- felix-w24-bl-close-6057-superseded | open | HUMAN-GATED (PR #6057 still OPEN) — LEAVE OPEN.

## PHANTOM sub-rows — named in D164 but NEVER filed as tasks (would 404 on close)

- felix-w24-bl-census-floor — NOTFOUND under every slug variant (bare, task- prefix, -annotation suffix).
- felix-w24-bl-transfer-needs-detector-map — NOTFOUND likewise.
  Only 2 of the "four binding sub-rows" exist as tasks (config-hash-line-consistency #13, multiclause-annotation-review #14). Decide must drop census-floor and transfer-needs-detector-map from the close list.

## Special-case identities

- felix-w22-bl-recorder-bounds: real slug is `task-felix-w22-bl-recorder-bounds` (the bare slug 404s — needs the task- prefix). open/published/claim=null. Title: "Recorder persistence bounds — cap the codex runtime_text accumulator + validate source_markdown size (the durable third seam)". Per D169 it closes superseded-by-S6 (#11858) at merge — NOT a D164 PAID close.
- task-e98797b38ca3b51e: open/published/claim=null. Title: "Seal the realtime broadcast card projection — card_from_broadcast/3 applies the to_card/4 field-visibility gate (fail-closed)". Duplicate of merged #5914 (W19). NOT in the D164 table; it is a stranded-open superseded row that should be closed separately.

## Draft task-966de76b9dd92783 (pg_catalog broadening) — fix wording VERBATIM

status=draft, lifecycle=open, doc_id=drafts.task-966de76b9dd92783, claim=null, github issue 11866 (synced), parent=task-96a908af98698118, priority 2. READABLE via bp task get (NOT invisible).
Stored fix text (brief + description, identical): "extend assert_member_tables!/1's existence/allow check to reject any table not in the public-schema allow-set regardless of schema qualification (reject schema-qualified names outside the allowlist). Mutation-prove: a manifest naming a pg_catalog relation must be REFUSED. Scope: api/lib/barkpark/tenancy/workspace_bundle.ex assert_member_tables!/1 + a regression test."
VERDICT: the draft describes an ALLOW-SET-membership rejection, NOT the direction's `pg_catalog.pg_table_is_visible` one-liner, and it says nothing about keeping `relkind='r'`. If Decide wants the relkind-preserving `pg_table_is_visible` approach, it must AMEND the draft before publishing (birth verb = bp doc publish).
