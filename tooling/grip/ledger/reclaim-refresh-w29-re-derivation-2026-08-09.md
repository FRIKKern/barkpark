# Reclaim refresh — re-derivation recipes (wave 29 verifier, 2026-08-09)

Every number in `dr-w28-bl-reclaim-20-column-a-closes-and-three-draft-twins` must be
re-derived at read time. These are the exact commands. Ground at write time:
`origin/main = c2de1e51cd029d3f47717eec6c53a81b55970364`; epic roster read 2026-08-09 ~12:05Z;
`cloud-db-1` read 2026-08-09 12:12:39Z.

## Roster (all counts)

    bp task get task-fb4fb869490b4213 -o json > epic.json
    python3 - <<'EOF'
    import json
    from collections import Counter
    d=json.load(open('epic.json')); ch=d['children']
    print(d['child_count'], Counter(c['lifecycle_status'] for c in ch))
    op=[c for c in ch if c['lifecycle_status'] in ('open','in_progress')]
    print('open+ip', len(op))
    print('zero-met', len([c for c in op if (c.get('criteria_progress') or {}).get('met')==0]))
    print('no-criteria', [c['doc_id'] for c in op if not (c.get('criteria_progress') or {}).get('total')])
    print('fully-met-but-open', [c['doc_id'] for c in op
          if (c.get('criteria_progress') or {}).get('total')
          and c['criteria_progress']['met']==c['criteria_progress']['total']])
    for c in sorted(op,key=lambda x:x['inserted_at']):
        cp=c.get('criteria_progress') or {}
        print(c['inserted_at'][:19], cp.get('met'), cp.get('total'), c['doc_id'])
    EOF

`doc_id` is the only identifier the children payload carries — there is no `slug` key.
A `drafts.` prefix on `doc_id` IS the draft marker; a draft twin is any pair sharing a title.

## Column A — the three rows this wave newly pays

    # dr-w26-s2, criterion 7, verbatim recipe
    git show origin/main:cloud/lib/barkpark_cloud/platform_delivery.ex | grep -c transition   # 18, non-zero -> CLOSES

    # dr-w21-s5, criterion 9 ("PR merged"): #10757
    git log --oneline --first-parent 8e83b709a..origin/main | grep 10757                      # fd1182b06

    # dr-w26-s7, criterion 11: ROTTED, see below. Merge half paid by #11170
    git log --oneline --first-parent 8e83b709a..origin/main | grep 11170                      # efe37340c

## Rot case 1 — dr-w26-s3 (recipe rotted, code correct)

    git show origin/main:internal/cloudclient/deliveries.go | grep -c 'Carried \*bool'   # 0  (rc=1)
    git show origin/main:internal/cloudclient/deliveries.go | grep -n 'Carried'          # 121: Carried             *bool

gofmt column-aligns with multiple spaces; the single-space pattern can never match.
Corrected recipe: `grep -nE 'Carried +\*bool'`.

## Rot case 2 — dr-w26-s6 (unscoped grep can never be empty)

    git grep -l publish_clock origin/main | wc -l                                  # 11 files (was 10; grew this wave)
    git grep -l publish_clock origin/main -- cloud/lib internal api/lib cloud/priv  # rc=1, EMPTY

The corrected scope is already written down in `dr-w27-bl-reclaim-26-shipped-but-open-rows`
criterion 3 and it verifies.

## Rot case 3 — dr-w26-s7 criterion 11 (NEW; the criterion demands deleting its own proof)

    git grep -c 'runner_queue_len\|build_slots' origin/main -- api/ cloud/ internal/ web/ js/
    # origin/main:api/lib/barkpark_web/controllers/instance_site_deploy_controller.ex:4
    # origin/main:api/lib/barkpark_web/router.ex:3
    # origin/main:api/test/barkpark/sites/deploy_runner_door_census_test.exs:2
    # origin/main:api/test/barkpark_web/controllers/instance_site_deploy_controller_test.exs:11
    # rc=0 -> the criterion's "returns nothing" is UNSATISFIABLE

All 20 lines are the deletion's own moduledoc epitaph plus the negative assertions
(`refute Map.has_key?(body, "build_slots")`) that PROVE the deletion happened.
The slice's own criterion 1 already uses the correct scope, and it is genuinely empty:

    for t in api cloud internal web js; do
      echo "$t: $(git grep -c 'runner_queue_len\|build_slots' origin/main -- $t/ | awk -F: '{s+=$NF} END{print s+0}')"
    done
    # api: 20  cloud: 0  internal: 0  web: 0  js: 0

Corrected recipe for criterion 11: scope to `cloud/ internal/ web/ js/` (exit 1), or to
`api/lib` excluding `#`-comment lines.

## Draft twins — four clusters, seven rows

    python3 - <<'EOF'
    import json
    d=json.load(open('epic.json'))
    for c in d['children']:
        if c['doc_id'].startswith('drafts.') or c['doc_id'].startswith('task-'):
            print(c['inserted_at'][:19], c['lifecycle_status'], c['doc_id'], '|', c['title'][:110])
    EOF

  1. `drafts.dr-w24-s3…` 6/7 vs published `dr-w24-s3…` open 6/7
  2. `drafts.dr-w24-s5…` 7/9 vs published `dr-w24-s5…` **in_progress** 8/9 (draft is STALER)
  3. `drafts.dr-w27-s6…` 7/10 vs published `dr-w27-s6…` open 9/10 (draft is STALER)
  4. `drafts.dr-w26-hg-gyldendal-operator-packet-corrected` 0/5 — NO published partner
  5. NEW: three drafts `task-93206ca8fd299ae7` (11:46:27Z), `task-c075a65ad4a4e98d` (11:47:02Z),
     `task-baa72f67d96766ce` (11:49:15Z), all titled *"crown-reconcile's scream cannot be heard,
     and --now accepts a relative date on the platform CI runs on"* — whose published twin
     `task-e04e0566ffc68738` (11:49:45Z) is **already `done`**, paid by #11216 / 2e72d2948.
     These three carry NO criteria at all, so they are invisible to any met/total census.

## Crown coverage — the four write events (answers "closed backlog or live hole?")

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' -c \
      \"select inserted_at::text, count(*), count(distinct sha), count(distinct build_seconds), \
        count(*) filter (where serving_since is null), string_agg(distinct delivering_run_id::text,',') \
        from platform_deliveries group by 1 order by 1\""
    # 2026-08-08 12:23:21.862544|1 |1|1|0|31255918184
    # 2026-08-09 09:48:56.884428|8 |7|1|8|31306459823
    # 2026-08-09 11:41:17.514285|12|6|2|0|31311142804
    # 2026-08-09 11:48:13.286357|8 |4|2|0|31311406817

Twenty-nine rows come from FOUR write events. Each event writes rows for the whole push
RANGE (7, 6 and 4 distinct shas) and stamps ONE `build_seconds` per target across every
sha in the range — so `count(distinct build_seconds)` is 2 where there are 6 shas.
`build_seconds` differs between targets (the criterion dr-w28-s1 asks for) while still
being wrong for every sha but one.

The db role is `barkpark_cloud`, the database `barkpark_cloud_prod` — `-U postgres` and
`-U barkpark` both answer `FATAL: role does not exist`.
