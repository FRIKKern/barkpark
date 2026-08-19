<!-- doc-tier: cold | canonical-for: taat-out-of-fence-filings-rederivation-2026-08-19 | budget: 3000tok -->

# Re-derivation: tenancy-auth-totality out-of-fence filings (2026-08-19)

Seven residues filed as published children of `api-read-path-security-sweep`.
Every source claim below is re-derivable from `origin/main`, not from a worktree.

## The filed set

| # | task id | residue | priority |
|---|---|---|---|
| 1 | task-3158c3be89815848 | `Repo.uuid_or_nil` docstring names `Ecto.CastError`; real raise is `Ecto.Query.CastError` | 2 |
| 2 | task-cd491bf64265ba6b | `caps.ex` carries a second copy of the phantom totality claim | 2 |
| 3 | task-33e8040eba9ec18d | cloud `authz.ex` mirror repeats "is TOTAL … never raises", unverified | 1 |
| 4 | task-cae55dc2581a0257 | `sub-056.json` filed intention quotes the phantom prose as evidence | 3 |
| 5 | task-5275ac6f76e3b93d | GET + POST `/v1/access` REACHABLE-CRASH; 500→403 contract change | 1 |
| 6 | task-26a7fe3d3b7e9d7c | `Tenancy.list_workspaces_for/1` is a 4th membership-query fork | 2 |
| 7 | task-5d37402e4666bedc | remove the two hand-rolled wrappers, AFTER the totality fix merges | 3 |

## Re-derive each source claim

    # 1 — docstring names the wrong exception module (line 16), aka: list too (line 20)
    git show origin/main:api/lib/barkpark/repo.ex | sed -n '10,30p'

    # 2 — the second phantom claim, and the is_binary-only guard under it
    git show origin/main:api/lib/barkpark_web/studio/caps.ex | sed -n '190,215p'

    # 3 — the cloud mirror's own totality assertion
    git show origin/main:cloud/lib/barkpark_cloud/accounts/authz.ex | sed -n '1,15p'

    # 4 — the machine-consumed intention quoting the prose
    git show origin/main:tooling/intentions/review-results/sub-056.json | grep -n -i total

    # 5a — fetch_workspace_id guards only is_binary and non-empty; "zzz" passes
    git show origin/main:api/lib/barkpark_web/controllers/access_controller.ex | sed -n '76,92p;179,184p'
    # 5b — mint/2 authorizes BEFORE any changeset
    git show origin/main:api/lib/barkpark/access.ex | sed -n '60,70p'

    # 6 — the fourth fork: %ApiToken{} arm has NO guard, binary arm accepts any binary
    git show origin/main:api/lib/barkpark/tenancy.ex | sed -n '824,854p'

    # 7 — the two hand-rolled wrappers
    git show origin/main:api/lib/barkpark_web/controllers/share_controller.ex | grep -n uuid_or_nil
    git show origin/main:api/lib/barkpark_web/controllers/share_link_controller.ex | grep -n uuid_or_nil

## Verify the filings landed PUBLISHED

    bp task get api-read-path-security-sweep -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['child_count'])"
    # 107 before this batch, 114 after.

    for id in task-3158c3be89815848 task-cd491bf64265ba6b task-33e8040eba9ec18d \
              task-cae55dc2581a0257 task-5275ac6f76e3b93d task-26a7fe3d3b7e9d7c task-5d37402e4666bedc; do
      bp doc get task $id -o json | python3 -c "
    import json,sys
    d=json.load(sys.stdin); doc=d.get('document',d); ac=doc.get('acceptance_criteria') or []
    print(doc['_id'], doc.get('_draft'), doc.get('parent_id'), len(ac),
          all(set(c)=={'criterion','met','evidence'} for c in ac))"
    done

## Traps hit while filing (cost real time)

1. **`bp task ls --parent <id>` DOES NOT EXIST.** It exits 0 with
   `{"error":{"code":"usage",...},"ok":false}`. Piped into `len(json.load(...))`
   that dict has 2 keys, so the counter **prints `2` no matter what** — a vacuous
   green. Use `bp task get <parent> -o json` → `child_count` / `children`.
2. **Publish wall needs weighted tags**, not bare label strings:
   `[{tag, strength 1-100 all distinct, rationale}]`, and every `tag` must already
   be a **registered `type:tag` document**. `tooling` is not registered (204 are);
   `bp doc ls tag --limit 300 -o json` is the roster.
3. `bp task create --publish` that fails the wall still **creates the draft**.
   Recover with `bp doc patch task <id> --set tags:=…` then `bp doc publish task <id>` —
   there is no `bp task update` verb.
4. `--set k:=<json>` is passed to a JSON parser: an apostrophe inside a
   single-quoted shell argument silently truncates the value and the error blames
   the JSON, not the quoting. Keep prose inside `:=` values apostrophe-free.
