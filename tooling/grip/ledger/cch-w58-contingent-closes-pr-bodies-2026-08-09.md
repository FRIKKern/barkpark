# cch wave 58 — re-derivation recipes: the two contingent arrears closes + the w54-bl coverage question

Measured 2026-08-09 against `origin/main` = `989b19577e8fa108146807cdd84a3d48d011d9bc`.
Verifier lane `contingent-closes-pr-bodies`. No repo edits outside this file.

## R1 — the two PR bodies (the evidence the two contingent criteria need)

```
gh pr view 11015 --json body,mergeCommit,state,mergedAt -q '.state, .mergedAt, .mergeCommit.oid, .body'
gh pr view 11016 --json body,mergeCommit,state,mergedAt -q '.state, .mergedAt, .mergeCommit.oid, .body'
```

Both MERGED. 11015 -> `3bd53abdf1033c28f39155e223a2f121b950af61` @ 2026-08-08T23:47:56Z.
11016 -> `085cc8719bd1f8a568e5ea42c3d66893f13e462d` @ 2026-08-08T23:48:04Z.

## R2 — the four required contexts on each PR's HEAD (the merge-gated criteria)

```
gh api "repos/FRIKKern/barkpark/commits/$(gh pr view 11015 --json headRefOid -q .headRefOid)/check-runs?per_page=100" \
  -q '.check_runs[] | "\(.conclusion)\t\(.name)"' | sort -u \
  | grep -E "Cloud gate|Console gate|Elixir gate|PR references an active task"
```

11015 head `6d1c6ce2caf0963affa445586e037dc2e43adb68`; 11016 head `1f16ecb2f2b286ba2236bc6f9bc32c38c6bf8551`.
Both: all four `success`.

## R3 — the ONE absent clause (cch-w56-s3 criterion 5)

```
gh pr view 11015 --json body -q '.body' | grep -n "notifications.ex\|390"
```

Returns ONE line, and it is `notifications.ex:930` (the reader predicate). `390` appears nowhere.
The criterion demands the body "names the tension with the per-team argument at notifications.ex:390-400".
That argument is real and is at that address:

```
git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '385,402p'
```
-> "THE TENANCY RULING, stated because the guard cannot make it. A fleet-wide digest fanned to
every team's members would be a CROSS-TEAM DISCLOSURE ... So the digest is PER-TEAM".

The body's own cross-team paragraph exists and is strong, but argues the OPPOSITE half
(seam-consistency: `require_platform_operator`, `/v1/operator/fleet` cross-team by name).

## R4 — w54-bl's enumerated sites vs. the wave-58 crown sites

```
bp task get cch-w54-bl-other-admin-token-backed-paths-ignore-suspension -o json
git grep -n "reveal_admin_token\|instance_admin_token\|mint_agent_token\|mint_public_read_token" origin/main -- cloud/lib
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | grep -n "suspended: true"
```

w54-bl amended criterion 1 enumerates SIX: router.ex `2368`, `11189`, `11211`, `12322`,
verify.ex `131`, and `dispatch_instance_api/4` (router.ex `10794`, fed by `Usage.instance_admin_token/1`
at `10816`). The four router numbers are ALREADY STALE on 989b19577 — live: `2367`, `11129`,
`11151`, `12262`; the proxy pair is `10737`/`10756`.

NOT in the list, and each spends the decrypted bearer with NO suspension clause head:
- `registry.ex:3811 refresh_update_status/1` (wave 58's crown site; hourly `UpdateStatusWorker`)
- `registry.ex:4017 relay_admin/4` (14 callers)
- `registry.ex:3442 revoke_app_token/3`
- `usage.ex:718 / 756 / 772` — the usage-SAMPLER arm of `instance_admin_token/1`. The amendment
  replaced the original list's `usage.ex:898` with `dispatch_instance_api`, so the sampler is
  enumerated by NEITHER version.

Only two suspension clause heads exist in registry.ex: `3222 mint_studio_link`, `3342 mint_app_token`
(plus the route-level 409 at router.ex:2710).

## R5 — no prior-art row owns refresh_update_status

```
bp search query "refresh_update_status" --all -o json   # 62 task hits, all fuzzy FTS; none names it
```
