# cloud/priv/templates — MIRROR, do not hand-edit

These starter template trees (`blog-starter/`, `website-starter/`) are a byte-for-byte
mirror. **Canonical source:** `js/packages/create-barkpark-app/templates/<slug>` (the
published `create-barkpark-app` artifact). Edit templates there, then re-sync:

    node scripts/sync-starter-templates.mjs

Verify with `diff -r cloud/priv/templates/<slug> js/packages/create-barkpark-app/templates/<slug>`.
