# WGR — fence + live-collision recheck (web-glue robustness wave)

Pin: `origin/main` at recheck = `6015bedabd` (digest pin `228090798` is a proven ancestor, 2 commits behind; **zero** fence-file diff between them).

## Re-derivation recipes

```bash
cd /Volumes/SATECHI/github/barkpark

# 0) pin drift — is the digest pin still fence-equivalent to origin/main?
git merge-base --is-ancestor 228090798 origin/main && echo ANCESTOR
git diff --stat 228090798..origin/main -- api/lib/barkpark_web/controllers api/lib/barkpark_web/plugs   # empty == fence-equivalent

# 1) merged fixes already in the fence (the do-not-re-pave set)
git log --since=2026-08-10 --pretty=format:'%h %ad %s' --date=short --name-only origin/main \
  -- api/lib/barkpark_web/controllers api/lib/barkpark_web/plugs

# 2) the ARPSS reconcile-era security PRs vs the fence (all EMPTY = no collision)
for n in 12274 12289 12305 12306 12308 12309 12311 12322 12324 12325 12326; do
  echo "#$n $(gh pr view $n --json files --jq '[.files[].path]|map(select(test("barkpark_web/(controllers|plugs)")))|join(" ")')"
done

# 3) OPEN PRs holding fence edits
gh pr list --state open --limit 100 --json number --jq '.[].number' | while read n; do
  f=$(gh pr view $n --json files --jq '.files[].path' | grep -E '^api/(lib|test)/barkpark_web/(controllers|plugs)')
  [ -n "$f" ] && { echo "=== PR #$n ==="; echo "$f"; }
done

# 4) ACTIVE worktrees (HEAD <=3d old) holding fence edits, dirty or ahead-of-main
git worktree list --porcelain | awk '/^worktree /{w=$2} /^HEAD /{print w" "$2}' | while read w h; do
  age=$(git log -1 --format=%ct $h 2>/dev/null) || continue
  [ $(( ( $(date +%s) - age ) / 86400 )) -gt 3 ] && continue
  d=$(git -C "$w" status --porcelain | grep -E 'barkpark_web/(controllers|plugs)' | tr '\n' ' ')
  a=$(git diff --name-only origin/main...$h | grep -E 'barkpark_web/(controllers|plugs)' | tr '\n' ' ')
  [ -n "$d$a" ] && echo "WT $w [${h:0:8}] dirty=[$d] ahead=[$a]"
done

# 5) is an "ahead" branch actually already squash-landed? (content test, not ancestry)
git diff --stat origin/main <branch-sha> -- <fence-file>    # empty == already on main

# 6) primary-checkout dirty state — does it touch api/ at all?
git status --porcelain | grep 'api/' || echo NONE_UNDER_api/
```

## Verdicts

- **(a)** The assignment's four-file do-not-re-pave list is WRONG BOTH WAYS. `assign_default_scope.ex` (last touched 2026-05-25) and `derive_workspace_from_token.ex` (2026-07-13) carry **no** recent security fix; `share_controller.ex` / `share_link_controller.ex` last merged 2026-08-02 — their ARPSS fixes are still in OPEN PRs. The real merged-fix set inside the fence since 2026-08-10 is **twelve files**: `search_controller.ex`, `v1/media_controller.ex` (#12228), `query_controller.ex` (#12159, #12111), `plugs/cache_body_reader.ex` (#12073), `meta_controller.ex` (#12033), `bulldocs_ingest_controller.ex` + `bulldocs_source_controller.ex` (#11934, #11758), `legacy_controller.ex` (#11810, #11764), `plugs/optional_token.ex` + `plugs/require_token.ex` (#11765), `plugs/auth_write_rate_limit.ex` (#11767), `tasks_controller.ex` (#11694), `cycle_fleet_controller.ex` (#11697), `capabilities_controller.ex` (#11640).
- **(a′)** The eleven ARPSS reconcile-era security PRs (#12274…#12326) touch **zero** fence files.
- **(b)** Exactly **two** live code collisions: `share_controller.ex` (PR #12405, +87/-19) and `share_link_controller.ex` (PR #12404, +38/-1). Three older open PRs also hold fence edits: #11766 `capabilities_controller.ex`, #9600 `search_controller.ex`, #9530 `auth_controller.ex`. The media wave (`wf_2e8cf7e1-c56-*`, PRs #12447/#12433/#12436) is confined to `api/lib/barkpark/media`, `api/lib/barkpark/plugins/media.ex` and `api/test/barkpark/media` — it does **NOT** touch `media_controller.ex`. The web/templates wave (`wf_ebfdd19e-bf1-*`) is confined to `cloud/priv/templates`, `js/packages/create-barkpark-app`, `web/`.
- **(c)** Primary checkout dirt: **one** tracked modification (`.claude/workflows/bp-cloud-epic-charter.md`) + 177 untracked, of which 167 are `tooling/grip/ledger/*.md`. **Nothing under `api/`.**
