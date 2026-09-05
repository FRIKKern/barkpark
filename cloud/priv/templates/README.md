# cloud/priv/templates — MIRROR, do not hand-edit

These starter template trees (`blog-starter/`, `website-starter/`) are a byte-for-byte
mirror. **Canonical source:** `js/packages/create-barkpark-app/templates/<slug>` (the
published `create-barkpark-app` artifact). Edit templates there, then re-sync:

    node scripts/sync-starter-templates.mjs

Verify with `diff -r cloud/priv/templates/<slug> js/packages/create-barkpark-app/templates/<slug>`.

**This mirror is ENFORCED, not merely documented.**
`cloud/test/barkpark_cloud/templates/app_files_drift_test.exs` asserts byte-identity
in both directions and runs inside `Cloud gate`, a branch-protection-required check
(`.github/required-checks.json`). cloud.yml's dispatcher reads its path set from
`scripts/cloud-path-escape-check.sh`, whose `CLOUD_PATHS` names **both**
`cloud/**` and `js/packages/create-barkpark-app/templates/**` — so a PR that edits
either root runs the guard.

Consequence for anyone planning a change to these trees: a change **cannot be split
across two PRs** (one here, one in `js/`). Either half alone reds a required context.
Edit the canonical tree and re-sync in the **same commit**.
