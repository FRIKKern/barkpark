# Re-derivation recipe — PR #12519 final shape (share-token confinement), 2026-08-19

Purpose: the share-LINK wave mirrors an UNMERGED shape. These commands re-pin it.

```bash
# 1. State, head SHA, file fence, commit bodies
gh pr view 12519 --json state,mergedAt,headRefOid,mergeable,commits,files

# 2. Gate verdicts — the blocking Test gate vs the advisory Format failure
gh pr checks 12519

# 3. The Test run really ran on the FINAL head SHA (not an earlier push)
gh run view 32188933638 --json headSha,conclusion

# 4. WHICH file causes the advisory Format failure (never assume it is the PR's)
gh run view --job 95879135874 --log | sed -n '330,435p'

# 5. Prove the Format failure is INHERITED FROM main, not authored by #12519:
#    the three named files are byte-identical to origin/main and fail locally.
cd api
for f in test/barkpark/portable_doc/render/compose_test.exs \
         test/barkpark_web/controllers/media_synonyms_scoping_test.exs \
         test/barkpark_web/controllers/search_synonyms_scoping_test.exs; do
  diff -q <(git show origin/main:api/$f) $f && echo "SAME: $f"
done
mix format --check-formatted test/barkpark/portable_doc/render/compose_test.exs

# 6. Prove #12519's OWN two files are format-clean (so mirroring them is safe)
git fetch origin pull/12519/head:refs/remotes/pr/12519 -f
git show pr/12519:api/lib/barkpark_web/controllers/share_controller.ex > /tmp/f/share_controller.ex
cd api && mix format --check-formatted /tmp/f/share_controller.ex   # exit 0

# 7. Is it on main yet? (empty grep = NOT landed)
git show origin/main:api/lib/barkpark_web/controllers/share_controller.ex | grep -c workspace_admin?

# 8. The docs-only second commit that MOVED the shape (moduledoc 403-vs-422 note)
git show --stat e0a67ab7dcf2a07b70e4510cbc86776e02137d18

# 9. Merge sequence + the superseded sibling that still collides on the same file
bp task get arpss-w8-rework-12404-onto-membership -o json
gh pr view 12405 --json state,files; gh pr checks 12405
```
