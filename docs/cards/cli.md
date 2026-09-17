<!-- doc-tier: agent | canonical-for: bp-cli-overview | budget: 450tok -->
# bp CLI

Plugin-dynamic Go CLI in `internal/cli/`. The verb tree derives from the capabilities manifest (`/v1/capabilities`); `Execute()` in cli.go dispatches builtins then manifest verbs. Write bodies: declared args seed, `--set k=v` merges strings, `--set k:=json` sends TYPED JSON verbatim, `--file`/stdin overrides all bar a declared body arg (`bulldocs publish <slug>`), which merges over it. Write verbs (`doc create/patch/delete/publish/unpublish`) ride manifest `mutation_op`+`set_key` → `{mutations:[{op:…}]}` (buildBody). `--set` merges SHALLOW into `content` (`--set 'blocks:=[…]'`); a dotted key and `content:={…}` are both REFUSED; `k:=null` on `doc patch` DELETES k. Single-quote JSON args.

Dev-loop builtins (scoped URLs `/w/<ws>/p/<project>/v1/…`, not flat BuildURL): `bp make schema <name>` prints a schema v2 skeleton; `bp make workflow <site>` prints the curl-only GitHub Actions builder TEMPLATE (prebuilt lane; contract in make_workflow.go's header); `bp seed <type> [--count N]` fakes drafts; `bp tinker`: query/doc/mutate REPL.

**Scaffy catalog-first** — check `scaffy/commands/` before hand-editing a repeated shape → scaffy/README.md.

- Full-screen: `bp paper` (portable-docs), `bp tasks` (task board) → docs/cards/tui.md.
- Support desk: `bp ticket` (inbox·show·answer·close) + `bp ticket-key` (mint·ls·rotate·pause·unpause·revoke) → docs/contracts/plugin-http-api.md.
- `docs/cli/**` is PATH FROZEN (cli.go refs it): error-exit-table.md, m0-decisions.md, HANDBOOK.md, manifest.schema.json + fixtures/*.json (Go tests read them).
- Go gate, LOCAL: `CGO_ENABLED=0 go build ./... && go vet ./internal/cli/... ./internal/manifest/... && go test ./internal/cli/... ./internal/manifest/...`; CI runs `./...` on Linux.

## Code anchors
- internal/cli/cli.go — func Execute
- internal/cli/builtins.go — func runWhoami, func runCapabilities
- internal/cli/paper_cmd.go — func runPaper
- internal/cli/errors.go — func exitForCode, func classifyError, (apiError).hint
- internal/cli/make_cmd.go — func runMakeSchema
- internal/cli/make_workflow.go — func renderDeployWorkflow, func runMakeWorkflow
- internal/cli/seed_cmd.go — func runSeed, func generateDoc
- internal/cli/tinker_cmd.go — func runTinker, func parseTinkerLine
