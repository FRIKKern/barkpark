# cch-w45 — reachability remainder (archives resurrect · site GitHub · /new flow)

Baseline: `origin/main` = `b00d793c0e2065e98a03fed6c4356245d897ee3a`.
Every command below reads origin/main directly — no worktree state.

## (a) Archive → Resurrect IS member-reachable

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1978,1980p'   # GET /v1/archives → Auth.require_user
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1905,1910p'   # GET /v1/barkparks → require_user_or_pat + ability "read"
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8427,8442p'   # POST /v1/resurrect → require_user + team_admin? → forbidden(required:"admin")
    git show origin/main:cloud/priv/static/app.js | sed -n '5846,5852p'                 # loadArchives() called unconditionally from loadFleet()
    git show origin/main:cloud/priv/static/app.js | sed -n '1948,1955p'                 # archiveRowHtml renders .archive-resurrect-btn on row.resurrectCommand only
    git show origin/main:cloud/priv/static/app.js | sed -n '1920,1928p'                 # archivesModel sets resurrectCommand from slug — no authority input
    git show origin/main:cloud/priv/static/index.html | grep -n '#fleet'                # static, ungated Fleet nav link

Verdict: rendered lie confirmed. Census row `:1938 openResurrectModal` is CORRECT.

## (b) Site GitHub — the census pins the two admin routes; the member one has no census row

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -nE 'sites/:id/github'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '6930,6932p'   # POST /v1/sites/:id/github → with_team_site (NO admin gate)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '11006,11015p' # with_team_site default auth = Auth.require_user
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7002,7005p'   # POST /v1/sites/:id/github/connect → Auth.require_team_admin
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7031,7034p'   # DELETE /v1/sites/:id/github → Auth.require_team_admin
    git show origin/main:cloud/priv/static/__binding_census.mjs | sed -n '284,285p'

Verdict: census rows 284/285 are ACCURATE (both `A_TADMIN`). The plain
`POST /v1/sites/:id/github` is member-tier and has NO console call site and NO
census row — not a hole, but the census's route strings must not be read as
covering it.

## (c) /new — two of four are member-reachable, one is NOT, one is URL-only

    git show origin/main:cloud/priv/static/app.js | sed -n '19510p'                     # render() takeover: if (isNewFlow()) { renderNewFlow(); return; }
    git show origin/main:cloud/priv/static/app.js | sed -n '16686,16700p'               # renderNewFlow: authed → renderNewLaunch; ?bp= + authed → newStartProgress
    git show origin/main:cloud/priv/static/app.js | sed -n '16812,16822p'               # renderNewLaunch: Launch button, NO role predicate
    git show origin/main:cloud/priv/static/app.js | sed -n '17383,17384p'               # newCheckStatus reads GET /v1/barkparks (member tier)
    git show origin/main:cloud/priv/static/app.js | sed -n '17410,17417p'               # bp.host → newRenderReady; provision_status "failed" → newRenderFailed
    git show origin/main:cloud/priv/static/app.js | sed -n '17429,17438p'               # newRenderReady: boot = GET …/bootstrap, gh = GET /v1/github/installation
    git show origin/main:cloud/priv/static/app.js | sed -n '17600,17602p'               # oneClick = vercelClaimHtml(boot && boot.vercel)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '3750,3753p'   # GET /v1/barkparks/:id/bootstrap → Auth.require_team_admin
    git show origin/main:cloud/priv/static/app.js | sed -n '17504,17507p'               # newGithubHtml gates on tpl.deployable && gh.connected
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4115,4116p'   # GET /v1/github/installation → Auth.require_user

Verdict:
- `newLaunch` (:16345) — member-reachable, already honest AFTER click
  (`newLaunchRefusalToast` reads `data.required`), still unpredicated at offer time.
- `newCreateRepo` (:17173) — member-reachable (its render predicate is a
  member-tier read), unpredicated. TRUE census row.
- `newVercelDeploy` (:17136) — NOT member-reachable: `#new-vercel-claim` renders
  only from `boot.vercel`, and `boot` is `GET /v1/barkparks/:id/bootstrap`
  (admin). For a member `boot` is null → the button never paints.
  Census row 304's "a plain member can see, click, and be refused for" is FALSE.
- `newRenderFailed`'s `#new-retry` (:17284) — reachable only by typing
  `/new?template=…&bp=<id>`; nothing in the console links a member there.

## Bonus (corroborates the direction's dead-site claim)

    git grep -n 'inst-retry' origin/main -- cloud/
    # → exactly ONE hit, the wire site itself (app.js:6903). No markup anywhere.
