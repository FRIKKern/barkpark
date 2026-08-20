# http-edge-truth W1 verify — siblings-and-ledger re-derivation recipes (2026-08-08)

Every row below is one command that re-derives the fact from scratch. Verifier phase, wave 1
of the http-edge-truth epic (task-02ce7e5183108eb3). No repo edits beyond this file.

## (a) E2's wave paper never targets paper_revision_headers.ex

    bp paper view anonymous-metering-wave-2026-08-08 > /tmp/e2.txt
    grep -c 'paper_revision_headers' /tmp/e2.txt        # -> 1
    grep -n  'paper_revision_headers' /tmp/e2.txt        # -> line 69 only, an OBSERVATION about E1

E2 wave-1 slices = (1) RequestStats route-class instrument at the
[:phoenix,:endpoint,:stop] telemetry handler (request_stats.ex), (2) robots.txt,
(3) reader query-shape dedupe. No plug-telemetry slice; E2 explicitly rejects a
per-pipeline stamping plug ("stamping would edit router.ex and D7 forbids that this wave").

## (b) dr-w1-s1 real slug + the stuck criterion

    bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys;[print(c['doc_id']) for c in json.load(sys.stdin)['children'] if c['doc_id'].startswith('dr-w1-s1')]"
    # -> dr-w1-s1-graph-visibility-bound-readmit
    bp task get dr-w1-s1-graph-visibility-bound-readmit -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['doc']['acceptance_criteria'][6])"

acceptance_criteria index 6 (7th of 8), met:false, evidence "":

    HUMAN SECURITY GATE (charter D17 / site-spawner D106): a NAMED independent
    reviewer has read the diff and approved. Closed by the lead.

index 7, met:false, evidence "":

    PR merged and the Elixir gate reported green on the merge commit. Closed by the lead.

6/8 met. The negative template: an unowned pre-merge criterion with no dispatch
mechanism and no artifact path — it can never self-discharge.

## (c) absorption map prescribes NO step7 recipe; the CROWN does

    bp paper view hobby-hardening-absorption-map | grep -n -i 'step7'
    # -> only 3 hits; the operative one is JUDGMENT CALL #1 "left to the user / capstone"
    bp paper view hobby-hardening-capstone | sed -n '1036,1050p'
    # -> "ABSORB into E1 - close it into the new epic by name; never re-derive."

No timing/closure sequence is stated anywhere in either paper.

## (d) sync_tags consumers DO exist (webhook/mutation path), none on the read envelope

    grep -rn --exclude-dir=node_modules 'sync_tags\|syncTags' js/packages/nextjs/src js/packages/core/src web/app internal
    # consumers: js/packages/nextjs/src/revalidate/index.ts:149-152 (-> revalidateTag)
    #            web/app/api/barkpark/webhook/route.ts:96
    #            js/packages/core/src/listen.ts:501 (SSE event field, parse only)
    # producers: api query_controller.ex, search_controller.ex, media_controller.ex,
    #            webhooks/dispatcher.ex:140, media/delivery/events.ex:87

## (e) zero PRs touch api/lib/barkpark/media/**

    gh pr list --state all --limit 200 --json number,title,state,isDraft,mergedAt,files > /tmp/prs.json
    python3 -c "import json;d=json.load(open('/tmp/prs.json'));print(len([p for p in d if any('media' in f['path'] for f in p['files'])]))"
    # -> 0, across PRs #9849-#10736, none at the 100-file API cap (max 12 files)
    git log origin/main --date=short --pretty='%h %ad %s' -1 -- api/lib/barkpark/media/
    # -> d6c6f94af 2026-07-30 style(api): reformat 86 files ... (#8160)  [pure reformat]

## Cross-epic premise dependency (NOT a file-edit collision)

    git show origin/main:api/lib/barkpark_web/endpoint.ex | sed -n '56,76p'
    # Plug.Static at :56, Plug.Telemetry at :75

E1 slice 3 edits the Plug.Static region at :56. E2 slice 1's charter CORRECTION (a)
-- "a static class is structurally unemittable, Plug.Static halts before Plug.Telemetry" --
is a premise ABOUT that region. E2's fence sweep called the surface clear because E1
had zero child tasks when it scanned.
