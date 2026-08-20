# v5-bp-prereqs — what `bp login` writes, how to derive the host, and how doctor.sh behaves without bp

Every command runs from the repo root. Code facts read `origin/main`, never the checkout.

## (a) `bp login` writes ONLY the three cloud_* keys

    git show origin/main:internal/cli/login_device.go | sed -n '168,183p'

Prints the sole write site:

    if res.Status == cloudclient.DevicePollApproved {
        cfg.CloudURL = base
        cfg.CloudToken = res.Login.Token
        cfg.CloudTeam = res.Login.TeamID
        if serr := SaveConfig(cfg); serr != nil {

The password path is identical (`cloud12_cmd.go:118` doc comment: "stores CloudToken + CloudURL (+ team) in config 0600").
`server` / `token` are written by a SEPARATE tail — `finishLoginConnect` → `connectToBarkpark` → `setup.Execute`:

    git show origin/main:internal/cli/cloud12_cmd.go | sed -n '261,266p'   # TTY gate
    git show origin/main:internal/cli/cloud12_cmd.go | sed -n '403,420p'   # setup.SetupPlan{Server, Token, …}

The gate is `if !out.isTTY || out.machineOut() { return exitOK }` — so a HEADLESS / `-o json` `bp login`
leaves `server` and `token` UNSET. Runbook consequence: `bp login` alone is not sufficient prereq;
`bp setup --target cloud` (or `bp use <name>`) is what points bp at a content server.

## Config file: JSON at ~/.config/barkpark/config.json, 0600, atomic rename

    git show origin/main:internal/cli/config.go | sed -n '259,265p'    # ConfigPath → filepath.Join(home,".config","barkpark","config.json")
    git show origin/main:internal/cli/config.go | sed -n '317,345p'    # SaveConfig: MkdirAll 0700, CreateTemp+rename, 0600
    git show origin/main:internal/cli/config.go | grep -n 'json:"'     # key names

Live file keys:

    python3 -c "import json;print(list(json.load(open('$HOME/.config/barkpark/config.json'))))"
    # ['server','token','workspace','project','dataset','cloud_url','cloud_token','cloud_team','known_servers']

## (b) Host derivation — `bp whoami -o json` is the recipe, NOT config.json

    bp whoami -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['server'])"
    # https://guerrilla.barkpark.cloud

Why not config.json: precedence is `flags > env(BARKPARK_*) > .barkpark.json (repo) > config.json > defaults`
(`docs/cli/HANDBOOK.md:38`). Mutation proof that whoami resolves the whole chain:

    BARKPARK_SERVER=http://localhost:4000 bp whoami -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['server'],d['source'],d['reachable'])"
    # http://localhost:4000 env False

`.source` names which layer won (`saved` / `env`). `bp capabilities -o json | .server.base_url` is the
SERVER's self-reported public URL (also `https://guerrilla.barkpark.cloud`) — that is the right value for
building `/papers/<slug>` URLs, but it costs a round trip and lies about nothing only while reachable.

TRAP: `bp whoami` exits 0 even when the server is unreachable.

    BARKPARK_SERVER=http://localhost:4000 bp whoami -o json >/dev/null 2>&1; echo $?   # 0

A prereq gate must assert on the JSON fields (`reachable == true`, `token_present == true`,
`cloud.logged_in == true`), never on the exit code.

## (c) scripts/doctor.sh — advisory, and SILENT about a missing bp in hook mode

    bash -n scripts/doctor.sh && echo SYNTAX_OK
    grep -n 'no bp on PATH' scripts/doctor.sh     # 154:  skip "no bp on PATH — install: make cli-install"

`skip()` is defined `skip() { [ "$HOOK" = 1 ] || printf '  – %s\n' "$*"; }` (line 20) — it prints NOTHING
under `--hook`. Mutation proof (bp removed from PATH):

    env PATH=/usr/bin:/bin:/usr/sbin:/sbin bash scripts/doctor.sh --hook; echo RC=$?
    # (no bp line at all) … RC=0
    env PATH=/usr/bin:/bin:/usr/sbin:/sbin bash scripts/doctor.sh | grep -n 'bp'
    # 4:  – no bp on PATH — install: make cli-install

And the script always exits 0 (`exit 0   # advisory, never blocks a session or a script chain`, line 199).
The SessionStart hook that runs it IS tracked and therefore travels with the clone:

    git show origin/main:.claude/settings.json | grep -n doctor
    # "command": "bash scripts/doctor.sh --hook"
