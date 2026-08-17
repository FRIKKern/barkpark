# Onboarding W4 — ledger-dedup re-derivation recipes (2026-08-17)

Verifier [ledger-dedup] for onboarding-composition-wave-2026-08-17. Each row: a dedup
verdict + the one command that re-derives it. No mutations performed.

## (a) Does cli-reliability-wave-2026-07-23 own BP-ONB-18 / BP-ONB-20?  NO.

Verdict: The paper is exclusively doctor.sh compare-target + autoseed CI tripwire.
Zero ONB-18/ONB-20 references. BP-ONB-18 (target-mismatch receipt) and BP-ONB-20
(duplicate compare action) are owned by the residue umbrella onb-backlog-authoring-audit-residue
("genuine open CLI/onboarding gaps; split into per-item tasks when claimed"). The
residue umbrella's 18/20 filings are therefore NOT blocked — they can proceed.

    bp doc get paper cli-reliability-wave-2026-07-23 -o json | grep -oiE "ONB-1[0-9]|ONB-2[0-9]|BP-ONB" | sort -u
    # -> (empty) : zero ONB refs in the paper
    bp task get onb-backlog-authoring-audit-residue -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["doc"]["content"]["description"])' | grep -o "BP-ONB-1[68]\|BP-ONB-20"
    # -> BP-ONB-18 ... BP-ONB-20 : the umbrella names them as its own gaps

## (b) install-404 task-3caa69c0537d08a9 — closeable now?  ALREADY CLOSED (a month ago).

Verdict: Closed 2026-07-12 by lead, epoch 2, remediated+proven (gh release edit
re-pointed cli-v1.14.0 --latest; clean-env curl|sh proof 2.18s). The direction's
"closeable now that #2797 shipped" premise is STALE — nothing to do.

    bp task get task-3caa69c0537d08a9 -o json | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"] if "lifecycle_status" in d else d.get("content",{}).get("lifecycle_status"), d["claim"]["closed_at"], d["claim"]["closed_by"])'
    # -> ... 2026-07-12T12:40:14 lead  (claim shows closed_at/closed_by=lead, epoch 2)

## (c) New slice candidates — existing task owner?  NONE for all six.

device-loop resilience, device-receipt account identity, signup-retry, onramp
partial-write, whoami CLI-freshness leg — bp search (task-typed) returns only PAPERS,
zero owning tasks. dr-w6-followup does NOT exist as a task id (not_found). published_doc
producer (cch-w55) has no task owner and is a cloud/ concern -> cross-link only, out of fence.

    bp task get dr-w6-followup -o json
    # -> {"error":{"code":"not_found",...}}  : no such task
    bp search query "signup retry token strand committed account" -o json | grep '^{' | python3 -c 'import json,sys;print([x["id"] for x in json.load(sys.stdin)["documents"] if x["type"]=="task"])'
    # -> [] : no task owns it

## (d) onb-backlog-cloud-url-fleet-backfill — 3 criteria verbatim; gyldendal leak LIVE today.

    CRIT1 Every live managed instance carries BARKPARK_CLOUD_URL and renders the Cloud login button — evidence: curl /login shows the button on a sample instance
    CRIT2 gyldendal.barkpark.cloud reports base_url equal to its own host (no localhost:4000 leak) after redeploy — evidence: curl /v1/capabilities base_url
    CRIT3 A complete instance inventory records changed, already-correct, failed, and excluded hosts; backfill is idempotent, redacts secrets, health-checks each restart, and has a rollback path.

    curl -s https://gyldendal.barkpark.cloud/v1/capabilities | python3 -c 'import json,sys;print(json.load(sys.stdin)["server"]["base_url"])'
    # -> http://localhost:4000  : CRIT2 STILL UNMET on 2026-08-17
