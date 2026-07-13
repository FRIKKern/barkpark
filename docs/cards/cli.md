<!-- doc-tier: agent | canonical-for: bp-cli-overview | budget: 450tok -->
# bp CLI

Plugin-dynamic Go CLI in `internal/cli/`. The verb tree is a pure function of the server's capabilities manifest (`/v1/capabilities`); `Execute()` in cli.go dispatches builtins then manifest verbs. Write bodies: declared args seed, `--set k=v` merges strings, `--set k:=json` sends TYPED values (number/bool/array/object, verbatim), `--file`/stdin overrides all. Write verbs (`doc create/patch/delete/publish/unpublish`) ride manifest `mutation_op`+`set_key` → `{mutations:[{op:…}]}` (buildBody). `--set` writes into `content` — use `--set 'blocks:=[…]'`, never `--set 'content:={…}'` (double-nests to content.content, no-op; server warns). Single-quote JSON args with spaces.

Dev-loop builtins (scoped URLs `/w/<ws>/p/<project>/v1/…`, not flat BuildURL): `bp make schema <name>` prints a schema v2 skeleton; `bp seed <type> [--count N]` fabricates drafts; `bp tinker` is a query/doc/mutate REPL. Errors carry a `hint()`; exit ladder (0–8) unchanged.

- Full-screen (→ docs/cards/tui.md): `bp paper` renders portable-docs; `bp tasks` opens the live task board.
- Error→exit-code mapping in errors.go (canonical table below).
- Support desk: `bp ticket` (operator-only: inbox·show·answer·close), `bp ticket-key` (mint·ls·rotate·pause·unpause·revoke). A `bptk_` key is tier `none`; submitters file/list/reply via curl on the `mint` handoff card (api-v1.md §8a, printed by `bp ticket-key mint`).
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
