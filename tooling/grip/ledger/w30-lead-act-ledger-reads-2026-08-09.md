# Re-derivation recipes — wave 30 verifier [lead-act-ledger-reads]

Read date: 2026-08-09. Server: guerrilla.barkpark.cloud. bp build 0789ab90a (2026-08-07).

## 0. The read path works. Premise refuted.

    bp task get dr-w28-s1-crown-records-what-the-box-served -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['doc_id'],d['status'],d['lifecycle_status'])"
    bp task show dr-w28-s1-crown-records-what-the-box-served     # prints "note: `task show` is not a verb — running `barkpark task get`" then the doc
    bp search "dr-w28-s1-crown-records-what-the-box-served"      # prints "note: `search` has one verb — running `barkpark search query`", count=4
    bp search query "dr-w28-s1-crown-records-what-the-box-served" -o json   # count=4, first id is the exact row

Both bare forms AUTO-CORRECT and succeed. A genuine miss is unambiguous:

    bp task get dr-w30-nope -o json   # {"error":{"code":"not_found",...},"ok":false}

## 1. The roster read (children live at the RESPONSE ROOT, not under .doc)

    bp task get task-fb4fb869490b4213 -o json > /tmp/epic.json
    python3 -c "import json;d=json.load(open('/tmp/epic.json'));print(d['child_count'],len(d['children']))"   # 249 249
    # d['doc']['children'] is ABSENT -> a reader that looks there gets 0 and reports a false absence.

Child projection carries only: criteria_progress, doc_id, execution_class, inserted_at,
lifecycle_status, title. status (draft|published), rev and updated_at need a per-row get.

Census:

    python3 -c "import json,collections;d=json.load(open('/tmp/epic.json'));print(collections.Counter(c['lifecycle_status'] for c in d['children']))"
    # open 168 / done 73 / cancelled 8   (D507 read 228 children: 146/73/8/1)

## 2. Draft twins — four clusters, seven rows, NONE discarded

    python3 -c "import json;d=json.load(open('/tmp/epic.json'));[print(c['inserted_at'],c['doc_id'],c.get('criteria_progress')) for c in sorted(d['children'],key=lambda x:x['inserted_at']) if c['doc_id'].startswith('drafts.')]"

Draft vs published progress diverges — the draft is a stale fork carrying LOWER met counts:

| slug | published | draft |
|---|---|---|
| dr-w24-s3-custom-host-cannot-steal-a-url | 6/7 | 6/7 |
| dr-w24-s5-the-rulings-become-readable | 8/9 | 7/9 |
| dr-w27-s6-conflicted-pr-stops-asserting | 9/10 | 7/10 |

`bp task get <id-without-drafts-prefix>` on a draft-only row SILENTLY serves the draft:

    bp task get task-93206ca8fd299ae7 -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['doc_id'],d['status'])"
    # drafts.task-93206ca8fd299ae7 draft

## 3. Lead-act negation by timestamp

D505/D507 landed in charter commit 97f2deb50 at 2026-08-09T15:35:36+02:00 = 13:35:36Z:

    git log origin/main -1 --format='%H %cI' -S "D507 — RECLAIM: REFRESH THE ROW IN PLACE" -- .claude/workflows/bp-deploy-reliability-charter.md

Every ordered row's last write PREDATES it:

    for id in dr-w25-hg-gyldendal-operator-stops-the-transmission \
              drafts.dr-w26-hg-gyldendal-operator-packet-corrected \
              dr-w27-bl-gyldendal-packet-409s-on-the-dedup-wall \
              dr-w28-bl-gyldendal-corrected-criterion-still-unsatisfiable \
              dr-w27-bl-reclaim-26-shipped-but-open-rows \
              dr-w28-bl-reclaim-20-column-a-closes-and-three-draft-twins \
              dr-w28-s1-crown-records-what-the-box-served \
              dr-w28-s4-followup-payload-key-census-deferral-wait; do
      printf '%-60s ' "$id"
      bp task get "$id" -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];c=d['content'];a=c.get('acceptance_criteria') or [];print(d['lifecycle_status'],d['updated_at'],sum(1 for x in a if x.get('met')),'/',len(a))"
    done

## 4. The wave-29 human reader does not exist on the installed binary

    bp cloud deployments -o json
    # {"error":{"code":"usage","message":"unknown cloud command \"deployments\" ..."},"ok":false}
    bp cloud status -o json   # works, 6 barkparks, this principal's workspace only —
                              # platform row b1259514 (team yo) is NOT visible, so the
                              # 71069eaa token rotation is UNVERIFIABLE through bp.
