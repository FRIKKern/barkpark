# Sweep-A NO-GAP consolidation — search-template done set (72 rows)

Verifier V3. READ-ONLY audit re-derivation recipe. Not committed by me (Decide commits).

## Claim proven
The two prior Sweep-A batch halves (rows 0-35 / 36-72, split by two surveyors who never
joined their sets) UNION to cover all 72 done rows exactly once — no gap, no overlap — and
EVERY cited #PR across all 72 rows resolves to a merge commit that is an ancestor of
origin/main. Consolidated into ONE table below.

## Denominator (re-derive from live L1)
    bp task get search-template-epic-goal -o json | jq -r '.children[].lifecycle_status' | sort | uniq -c
    # => 1 cancelled / 6 considering / 72 done / 38 open   (child_count 117 is TOTAL, not done)

## Enumerate the 72 done rows (exactly once — uniqueness proof)
    bp task get search-template-epic-goal -o json \
      | jq -r '.children[]|select(.lifecycle_status=="done")|.doc_id' > done72.txt
    wc -l done72.txt            # 72
    sort done72.txt | uniq -d   # EMPTY => no duplicate row => no overlap

## Extract every cited #PR per row, then the distinct set (84 PRs)
    for id in $(cat done72.txt); do
      bp task get "$id" -o json \
        | jq -r '[.doc.content,(.doc.claim.now|tostring)]|tostring' \
        | grep -oE '#[0-9]{3,6}' | tr -d '#'
    done | sort -un > cited.txt      # 84 distinct

## Resolve each #PR -> squash mergeCommit (all MERGED, baseRefName=main)
    gh pr view <PR> --repo FRIKKern/barkpark --json state,mergeCommit,baseRefName,mergedAt
    # all 84: state=MERGED, baseRefName=main, mergedAt set

## Ancestry proof — GitHub compare (L1), NOT local git
    # WARNING: the shared local checkout prunes objects mid-run (objects present one second
    # vanish the next under concurrent sessions) — local `git merge-base --is-ancestor` is
    # UNRELIABLE here. Use GitHub compare, the authoritative origin/main truth:
    gh api "repos/FRIKKern/barkpark/compare/main...<mergeCommit_oid>" -q '.status'
    # status == "behind"  => oid is an ancestor of main.  All 84 => "behind".

## Set-difference closes the no-gap: cited set == proven-ancestor set
    comm -23 cited.txt behind.txt   # EMPTY => every cited PR is an ancestor
    comm -13 cited.txt behind.txt   # EMPTY => every resolved PR was cited

## VERDICT
    72 rows enumerated once each (no gap, no overlap)
    71 rows cite >=1 merge; all 84 distinct PRs are ancestors of origin/main (e21bf40)
    1 row (stw11-bl-w11-slices-never-filed) cites NO merge = paper/finding lane (out of ancestry scope)
    => Sweep-A ancestry is 100% complete over the consolidated 72-row set. Zero false-done from ancestry.

## Consolidated table  row_idx|done_row|cited_prs|pr=mergeCommit(12ch)  [all ancestors of origin/main]
1|stw1-app-extraction|3493|3493=154cfdc0b65f
2|stw1-seed-corpus|3495|3495=3d0948e40bf9
3|stw1-provisioner-template-axis|3496|3496=d773665884cd
4|stw1-graph-theme-parity|3497|3497=c17a05888c97
5|stw1-premium-readme|2797,3498|2797=7e80c62d057d 3498=1c2ae335217d
6|stw-backlog-dashboard-create-ui|3534|3534=45225e9eacc2
7|stw-backlog-astro-variant|3538|3538=84f72dacff11
8|stw-backlog-readme-retrofit|3552|3552=73fe4147f3f1
9|stw-backlog-templates-deploy-trigger|3519|3519=fb1cc68f4f0f
10|stw2-manifest-catalog-go|3524|3524=198960ad850f
11|stw2-site-template-column|3529|3529=61ea18fa49d1
12|stw2-theme-env-wire|3536|3536=9dfe0f30c53f
13|stw3-phoenix-finder|3546|3546=4dce6801d8ad
14|stw4-console-live-stage-rail|3600|3600=6eb0a0540fd3
15|stw4-cli-create-deploy-motion|3601|3601=c0b0504199ca
16|stw4-deploy-failure-hints|3518,3602|3518=6dfcb7310d3b 3602=1eddf4b83b27
17|stw4-backlog-console-rollback-history|3641|3641=002ea9faa64d
18|stw4-backlog-freshness-badge|3640|3640=948f08acf76b
19|stw4-backlog-site-preflight|3642|3642=345b716fb57e
20|stw4-backlog-wire-console-harness-ci|3643|3643=ae53a8584e7b
21|stw4-backlog-node-selftest-ci|3518,3644|3518=6dfcb7310d3b 3644=127b651bde1d
22|stw5-rail-premium-styling|3639|3639=c7c8bacf8823
23|stw5-backlog-rail-active-eta-ring|3989|3989=f87418dfb29f
24|stw5-console-cache-revalidate|3665|3665=3d1a9825a074
25|stw5-finder-async-corpus|3746|3746=1465cffd1962
26|stw5-instance-deploy-node-copy|3374,3756|3374=a095778fe210 3756=d3e049f72599
27|stw5-cli-dataset-global-collision|3804|3804=da990b061dba
28|stw6-site-theme-column|3806|3806=9666953bbf7c
29|stw6-backlog-site-update-api|3971,3976,3982,4107,4108|3971=a142338c0d9e 3976=add4a582b35a 3982=e37817b129f2 4107=4d092b87dce9 4108=095fa7233dbb
30|stw6-node-resume-orphaned|3835|3835=a073017e7d7e
31|stw6-relay-env-differential|3806,3842|3806=9666953bbf7c 3842=46f9321f7a61
32|stw6-graph-flat-origin|3842|3842=46f9321f7a61
33|stw6-site-build-survives-restart|3835,3856,3857,3858,3859|3835=a073017e7d7e 3856=db941510777d 3857=a97fca4bdaf3 3858=5e20368c251c 3859=5518decd8dc1
34|stw6-engine-file-contract|3856|3856=db941510777d
35|stw6-deployrunner-reattach|3857|3857=a97fca4bdaf3
36|stw6-build-id-match-404|3858|3858=5e20368c251c
37|stw6-cp-restart-grace|3859|3859=5518decd8dc1
38|stw7-astro-finder-parity|3913,3915,3916|3913=9e6f4f98d060 3915=8e84f880c158 3916=f5ec245adbf0
39|stw6-backlog-stale-slot-env-purge|4102|4102=9c361001492d
40|stw7-finder-island-mount|3913,3915,3916|3913=9e6f4f98d060 3915=8e84f880c158 3916=f5ec245adbf0
41|stw7-build-seed-bake|3914|3914=9be8e4dfbc2b
42|stw7-finder-drift-tripwire|3779,3780,3842,3915|3779=fc7f22c2f96a 3780=8e5a4989db11 3842=46f9321f7a61 3915=8e84f880c158
43|stw7-parity-acceptance-harness|3916|3916=f5ec245adbf0
44|stw7-backlog-drafts-clamp-gap|837,6270|837=4c6fc64b022c 6270=9a92d85a30e8
45|stw7-backlog-astro-graph-landing-reintegrate|4119|4119=b09cd82eb9b4
46|stw8-site-update-api|3971|3971=a142338c0d9e
47|stw8-cli-site-settings|3971,3976|3971=a142338c0d9e 3976=add4a582b35a
48|stw8-console-theme-edit|3982|3982=e37817b129f2
49|task-2e8da7ff6bd0b7c2|4161|4161=a4370de52851
50|task-e6bed031ce5c6e17|4195|4195=db3a98956108
51|stw9-land-engine-truth|6210|6210=2354f0522545
52|stw9-ws-live-inline|4189,6211|4189=3a4d213bfcfa 6211=b9db13f28ee9
53|stw9-click-detail-truth|6212|6212=6675e1b1eb94
54|stw9-graph-constellation|6213|6213=a04f79dc454d
55|stw9-vendor-refresh|6114,6215|6114=af4fe3a3592e 6215=9ea52d23fb1c
56|stw9-node-content-auto-freshness|6216|6216=b2a92e3bcc07
57|stw9-journey-smoke-harness|6217|6217=6168df66b305
58|stw9-copy-honesty-mobile|6240|6240=5b1c5d303edb
59|stw9-graph-truncation-prop-wiring|6274|6274=4028efbef998
60|task-f8f33cebc90d4d15|6277|6277=608ca1cb7948
61|task-90266ebb72f45340|6238|6238=51dd7c8c7469
62|stw10-search-visibility-leak|6271|6271=45fa86ebdd08
63|stw10-loopback-boundary|6236,6272|6236=7b8e14436ded 6272=0e9fede4f2eb
64|stw10-backlog-flagship-health-pool|6284|6284=68b844c556e1
65|stw10-backlog-graph-n-plus-one|6274,6284|6274=4028efbef998 6284=68b844c556e1
66|task-bbe4686b8df2507f|6270,6271,7870|6270=9a92d85a30e8 6271=45fa86ebdd08 7870=051112568928
67|task-03a92ad1e8ecf5e5|6271|6271=45fa86ebdd08
68|task-8cea4ccd13d2317c|6333,6342,6345,6358,6366|6333=90ba3dcce3fc 6342=324919a2ae70 6345=3f55de3f1d7d 6358=ef823a5e1b54 6366=c856afbb6005
69|stw11-bl-w11-slices-never-filed|(no-merge:paper-lane)|N/A-paper-lane
70|stw11-a11y-invariants|6940|6940=32f2bea48610
71|stw11-vendor-freshness-gate|6215,6275,6307,6939|6215=9ea52d23fb1c 6275=123aaa9f4514 6307=3651da6cf3a8 6939=018045261c56
72|search-template-wave-12-log|12190,12203,12204|12190=b8ee136e90ef 12203=710c38f06a7e 12204=a5b7b4962974
