# cch-w73 github-callback-reachability — re-derivation recipe

Verifier: github-callback-reachability. Base: origin/main @ 83fe72c399a8 (`git rev-parse origin/main`).

## Claim 1 — NO server-rendered flow reaches POST /v1/github/installations → installation_not_found CLASSIFIES

Re-derive:

    B=$(git rev-parse origin/main)
    # (a) no setup_action handler anywhere in cloud
    git grep -in 'setup_action' $B -- cloud            # → ZERO hits
    # (b) no server-rendered/HEEx web template in cloud (only deploy-file templates)
    git ls-tree -r --name-only $B -- cloud/lib | grep -iE '\.heex$|\.eex$'   # → ZERO
    # (c) app.js never reads installation_id from redirect nor POSTs installations
    git grep -n 'v1/github/installations\|installation_id\|setup_action' $B -- cloud/priv/static/app.js  # → ZERO
    # the only two URLSearchParams sites read ?template= (new flow) and ?code= (device activation), app.js:19042 / 21858
    # (d) install affordance is a bare <a href=install_url> to github.com/apps/<slug>/installations/new (app.js:3311), no POST
    # (e) route author confirms unreachability: app.js:3279 "zero /v1/github handlers ... card is UNREACHABLE in the scenario corpus today"

emit site: `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4775,4776p'` → 422 installation_not_found, POST route is `Auth.require_team_admin` (4732). The intended GitHub App install-callback CONSUMER IS NOT BUILT on origin/main: nothing (server-rendered or SPA) reads GitHub's `?installation_id=&setup_action=install` redirect and POSTs it. installation_not_found is therefore NOT human-reachable → CLASSIFY (reason must cite: no setup_action route + no HEEx callback + no app.js installations POST).

## Claim 2 — github_error@openSiteGithub IS member-reachable (require_user)

Re-derive:

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4696,4718p'

GET /v1/github/repos → `conn = Auth.require_user(conn, [])` (4697); `{:error, _reason} -> json(conn, 502, %{error: "github_error"})` (4717-4718). app.js `openSiteGithub` (14579) calls `api("GET","/v1/github/repos")`; the `!r.ok` branch renders `friendly(r.data, "Couldn't load your repositories.")` — r.data = bare `%{error: "github_error"}`, no detail. Corpus pin already in tree: app.js:12690 + __app.test.mjs:13887 "openSiteGithub's first read (GET /v1/github/repos) is require_user". This is the quartet's highest-value, non-admin reader.
