# Re-derivation: bpb-search-config-workspace-attribution 9/9 over-claim (cloud-build done-set audit)

Row `bpb-search-config-workspace-attribution` (done, criteria 9/9, rev 5f77d9e6, evidence PR #3168 / merge fe24a6ae7).
Verdict: FUNCTIONALLY TRUE on origin/main a28e5ba5, but carries a PROVENANCE OVER-CLAIM on criteria 3 (D60), 4 (D58/422), 5 (D59).
Recommend IN-PLACE CORRECTION NOTE, not reopen (reopen would over-correct fully-live, tested capability).

## Facts (re-run against FRIKKern/barkpark, origin/main = a28e5ba53696)

    # 1. The row's OWN merge PR #3168 did NOT ship D58/D59/D60 — only W5 Slice A subset.
    gh api repos/FRIKKern/barkpark/pulls/3168/files --paginate --jq '.[].filename'
    #   -> touches surface_config{,s}.ex, tenancy*, workspace_bundle*, search_controller.ex,
    #      v1/media_controller.ex, router.ex, migration, surface_config_cross_tenant_test.exs.
    #      NO query_pipeline.ex, NO media/delivery/search.ex, NO read_threading test, NO 422 guard.

    # 2. D58 (nil-workspace admin WRITE -> 422) landed in W7 #3425, NOT #3168.
    gh api repos/FRIKKern/barkpark/pulls/3425/files --paginate \
      --jq '.[]|select(.filename|test("search_controller.ex"))|.patch' \
      | grep -iE 'token_workspace_id|nil_workspace_write_error|422'
    #   -> adds token_workspace_id/1, nil_workspace_write_error/1, 422. Merge d550504f73.
    #   PR title: "admin search-settings write fails CLOSED 422 on nil-workspace token (W7 D58)".
    gh api repos/FRIKKern/barkpark/pulls/3168/files --paginate \
      --jq '.[]|select(.filename|test("search_controller.ex"))|.patch' \
      | grep -iE 'token_workspace_id|nil_workspace_write_error|422'
    #   -> EMPTY. #3168 only adds workspace_id(conn) for get/upsert. No 422.

    # 3. D59 (READ-path threading into query_pipeline.ex) landed in W6 #3393, NOT #3168.
    gh api "repos/FRIKKern/barkpark/commits?path=api/lib/barkpark/search/query_pipeline.ex&sha=a28e5ba5&per_page=8" \
      --jq '.[]|{sha:.sha[0:9],msg:(.commit.message|split("\n")[0])}'
    #   -> 64f6714bc "feat(search): thread workspace_id into the scoped config read path
    #      (W6 D63/D64 — Slice A) (#3393)". #3168 does not appear.

    # 4. The criteria 3/4/5 evidence cites Commit b3824174a — a NEVER-MERGED orphan
    #    (the builder's "DONE-unmerged" branch commit). #3168 is a narrower merge.

## Both audit floors PASS — all claimed capabilities are LIVE on main

    gh api "repos/FRIKKern/barkpark/compare/fe24a6ae7cf114e6e96f61ff30cdca4d651a0ebc...a28e5ba5" --jq .behind_by  # 0  (#3168 W5)
    gh api "repos/FRIKKern/barkpark/compare/d550504f73db095c7f8339dba274c13287e12225...a28e5ba5" --jq .behind_by  # 0  (#3425 W7 D58/422)
    gh api "repos/FRIKKern/barkpark/contents/api/lib/barkpark/search/query_pipeline.ex?ref=a28e5ba5" \
      --jq .content | base64 -d | grep -nE 'workspace_id'   # 43,59,114,122,144,376 — D59 threaded, LIVE
    gh api "repos/FRIKKern/barkpark/contents/api/lib/barkpark_web/controllers/search_controller.ex?ref=a28e5ba5" \
      --jq .content | base64 -d | grep -nE 'token_workspace_id|nil_workspace_write_error|422'  # 259..504 — 422 guard LIVE

## Correction-note text (for Decide to stamp; do NOT reopen)

Criteria 3/4/5 stamp evidence citing unmerged orphan b3824174a and merge #3168; #3168
shipped only the W5 Slice A subset (write/admin-derivation/migration/E1/re-key/cross-tenant test).
True bearers on main: D58/422 = W7 #3425 (d550504f73); D59 read-threading = W6 #3393 (64f6714bc);
D60 seed follows the same W6 read-path work. All capabilities are ancestors of a28e5ba5 (behind_by==0)
and grep-present on main. Row is TRUE-on-main; the defect is intra-row attribution, not missing work.
