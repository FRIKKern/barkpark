<!-- doc-tier: agent | canonical-for: bp-cli-overview | budget: 450tok -->
# bp CLI

Plugin-dynamic Go CLI in `internal/cli/`. The verb tree is a pure function of the server's capabilities manifest (`/v1/capabilities`); `Execute()` in cli.go dispatches builtins then manifest verbs. Write bodies: declared args seed, `--set k=v` merges strings, `--set k:=json` sends TYPED values (number/bool/array/object, stored verbatim), `--file`/stdin overrides all. Write verbs (`doc create/patch/delete/publish/unpublish`) ride manifest `mutation_op`+`set_key` → `{mutations:[{op:…}]}` (buildBody).

Dev-loop builtins (hand-rolled scoped URLs `/w/<ws>/p/<project>/v1/…`, not flat BuildURL): `bp make schema <name>` prints a schema v2 skeleton (no network); `bp seed <type> [--count N]` fabricates sample drafts; `bp tinker` is a query/doc/mutate REPL. Errors carry a `hint()` line; exit ladder (0–8) unchanged.

- New builtin verb: copy builtins.go's `runWhoami`/`runCapabilities` (`*writer`+`globals`+`manifest.Context` in, exit int out).
- Full-screen (→ docs/cards/tui.md): `bp paper` renders portable-docs; `bp tasks` opens the live task board.
- Error→exit-code mapping in errors.go (canonical table below).
- Support desk: `bp ticket` (operator: inbox·show·answer·close; key-holder: ls·file·reply), `bp ticket-key` (mint·ls·rotate·pause·unpause·revoke). A `bptk_` key is tier `none`; submitters use the `mint` handoff card (api-v1.md §8a), which `bp ticket-key mint` prints by default.
- `docs/cli/**` is PATH FROZEN — cli.go references it; never move these files.

Canonical references:
- docs/cli/error-exit-table.md — exit codes + error-envelope mapping.
- docs/cli/m0-decisions.md — M0 decisions (scoped_admin no-blanket-hide, tier-projected ETag).
- docs/cli/HANDBOOK.md — operator manual (config, migration, safety).
- docs/cli/manifest.schema.json — manifest shape; docs/cli/fixtures/*.json are load-bearing for Go tests.

## Code anchors
- internal/cli/cli.go — func Execute
- internal/cli/builtins.go — func runWhoami, func runCapabilities
- internal/cli/paper_cmd.go — func runPaper
- internal/cli/errors.go — func exitForCode, func classifyError, (apiError).hint
- internal/cli/make_cmd.go — func runMakeSchema
- internal/cli/seed_cmd.go — func runSeed, func generateDoc
- internal/cli/tinker_cmd.go — func runTinker, func parseTinkerLine
