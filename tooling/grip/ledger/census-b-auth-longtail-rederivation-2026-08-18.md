# Census B — auth-adjacent + deploy/redirect long tail: re-derivation recipe

Verifier: `census-b-auth-longtail` (web-glue-robustness-wave-2026-08-18)
Pinned: `origin/main` = `6015bedabd301db9893bd300c90600ce307ae567` (NOT the digest's
`228090798b`, which is the primary checkout's stale local main — see D2 below).

All commands run from `api/`.

## D0 — the roster (17 modules, all present)

    cd api && for f in auth session webauthn login_ticket token social sso_routing \
      site_deploy instance_site_deploy legacy legacy_redirect access analytics \
      fleet_support_token admin_studio_redirect studio_redirect; do \
      git grep -c '' origin/main -- "lib/barkpark_web/controllers/${f}_controller.ex"; done
    git grep -c '' origin/main -- lib/barkpark_web/controllers/v1/media_processing_controller.ex

`media_processing_controller.ex` lives under `controllers/v1/`, not `controllers/`.
`analytics_controller.ex` EXISTS (21 lines) — the pagination surveyor's "absent" is refuted.

## D1 — INSTRUMENT TRAP: zsh does not word-split unquoted `$F`

A pathspec list held in a scalar (`F="a b c"; git grep ... -- $F`) is passed to git as
ONE argument under zsh. git grep then matches nothing and exits 1. Every "zero finding"
derived that way is an ARTIFACT. Use an ARRAY and quote-expand:

    F=(lib/barkpark_web/controllers/{auth,session,...}_controller.ex)
    git grep -nE "$RX" origin/main -- "${F[@]}"

## D2 — INSTRUMENT TRAP: `\{` is undefined in POSIX ERE

`git grep -E '^\s*(\{[^}]*\})\s*='` silently matches NOTHING. Use bracket classes:

    RX='^[[:space:]]*([{][^}]*[}]|\[[^]]*\]|%[{][^}]*[}])[[:space:]]*=[^=~]'

MUTATION CHECK the instrument before trusting its zero — it MUST fire on the digest's
known positives:

    git grep -nE "$RX" origin/main -- lib/barkpark_web/controllers/webhook_controller.ex \
      lib/barkpark_web/controllers/scim_users_controller.ex
    # expects webhook:104,177,178 and scim_users:56,77,104

## D3 — fence disjointness vs the sibling api-auth-accounts wave

    bp task get api-auth-accounts-correctness-audit -o json | head -c 3000
    git ls-tree -r --name-only origin/main -- lib/barkpark/auth lib/barkpark/accounts | grep barkpark_web

Sibling fences to CONTEXT modules under `lib/barkpark/{auth,accounts}/` only. The
grep for `barkpark_web` inside that tree returns EMPTY → disjoint. `auth_controller`,
`session_controller`, `webauthn_controller`, `login_ticket_controller`, `token_controller`
are in THIS wave's fence, not the sibling's.

## D4 — the four class sweeps (all with the array form)

    git grep -nE 'String\.to_integer|Integer\.parse' origin/main -- "${F[@]}"   # 0
    git grep -nE 'Repo\.get'                          origin/main -- "${F[@]}"   # 0
    git grep -nE '\brescue\b'                         origin/main -- "${F[@]}"   # 0
    git grep -n  'action_fallback'                    origin/main -- "${F[@]}"   # legacy, media_processing
    git grep -nE 'params\['                           origin/main -- "${F[@]}"   # 17 sites
    git grep -nE 'json\(conn, *%\{ *error'            origin/main -- "${F[@]}"   # 0 (no 200-on-error)

## D5 — the seven in-body hard binds, and why each is SAFE

`git show origin/main:./<path>` (the `./` prefix is REQUIRED from `api/`).

| Site | Callee | Why safe |
|---|---|---|
| auth:173 | `Privacy.erase_subject/1` | `Repo.transaction` + `Repo.update!`; no `Repo.rollback` → always `{:ok,_}` |
| auth:395, session:272 | `Accounts.build_email_token/2` | models `{:error,cs}`, but only reachable via `unique_constraint(:token_hash)` on a CSPRNG token / `assoc_constraint(:user)` on a just-fetched user → not request-reachable |
| auth:556 | `Accounts.disable_totp/1` | `Repo.update` of fixed nils on a loaded struct |
| auth:588 | `Accounts.stamp_session_mfa/1` | `Repo.update` of a timestamp on a loaded struct |
| session:141 | `Tenancy.Auth.create_membership/4` | pre-guarded by `nil <- membership(user, ws_id)`; builtin role; only a concurrent-insert race |
| session:411 | `Accounts.revoke_user_session_token/1` | body literally ends `{:ok, revoked}` — bind cannot fail |

## D6 — guards cited for the SAFE verdicts

    git grep -nA12 'def get_file('   origin/main -- lib/barkpark/media.ex      # Repo.uuid_or_nil
    git grep -nA8  'def get_grant'   origin/main -- lib/barkpark/access.ex      # Repo.uuid_or_nil + is_binary + catch-all
    git show origin/main:./lib/barkpark_web/controllers/token_controller.ex | sed -n '92,138p'
    # fetch_label/fetch_permissions/fetch_dataset: is_binary/is_list guard + catch-all → 422, never a raise
    git show origin/main:./lib/barkpark_web/controllers/auth_controller.ex | sed -n '744,752p'
    # centralized error/5 helper: every error path goes through put_status
