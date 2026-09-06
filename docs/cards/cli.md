<!-- doc-tier: agent | canonical-for: bp-cli-overview | budget: 450tok -->
# bp CLI

Plugin-dynamic Go CLI in `internal/cli/`. The verb tree derives from the capabilities manifest (`/v1/capabilities`); `Execute()` in cli.go dispatches builtins then manifest verbs. Write bodies: declared args seed, `--set k=v` merges strings, `--set k:=json` sends TYPED JSON verbatim, `--file`/stdin overrides all. Write verbs (`doc create/patch/delete/publish/unpublish`) ride manifest `mutation_op`+`set_key` → `{mutations:[{op:…}]}` (buildBody). `--set` merges SHALLOW into `content` (`--set 'blocks:=[…]'`); a dotted key and `content:={…}` are both REFUSED; `k:=null` on `doc patch` DELETES k. Single-quote JSON args.

Dev-loop builtins (scoped URLs `/w/<ws>/p/<project>/v1/…`, not flat BuildURL): `bp make schema <name>` prints a schema v2 skeleton; `bp seed <type> [--count N]` fakes drafts; `bp tinker`: query/doc/mutate REPL.

**Scaffy catalog-first.** Before hand-editing a repeated shape, check `ls scaffy/commands/` / `bp scaffy ls --remote`; prefer `bp scaffy run` (/papers/scaffy-benchmark: 3/3 vs 2/2). Builder prompts for catalog chores carry the `bp scaffy run` line.

- Full-screen: `bp paper` (portable-docs), `bp tasks` (task board) → docs/cards/tui.md.
- Support desk: `bp ticket` (operator: inbox·show·answer·close) + `bp ticket-key` (mint·ls·rotate·pause·unpause·revoke); `bptk_` keys are tier `none` — submitters use curl (api-v1.md §8a).
- `docs/cli/**` is PATH FROZEN (cli.go refs it).
- Go gate, LOCAL: `CGO_ENABLED=0 go build ./... && go vet ./internal/cli/... ./internal/manifest/... && go test ./internal/cli/... ./internal/manifest/...`. CI runs `./...` on Linux (64 KiB pipes); darwin pipes hold 512 B — read-after-call os.Pipe captures deadlock only here.

Canonical refs (docs/cli/): error-exit-table.md (exit codes ↔ envelope), m0-decisions.md, HANDBOOK.md, manifest.schema.json + fixtures/*.json (Go tests read them).

## Code anchors
- internal/cli/cli.go — func Execute
- internal/cli/builtins.go — func runWhoami, func runCapabilities
- internal/cli/paper_cmd.go — func runPaper
- internal/cli/errors.go — func exitForCode, func classifyError, (apiError).hint
- internal/cli/make_cmd.go — func runMakeSchema
- internal/cli/seed_cmd.go — func runSeed, func generateDoc
- internal/cli/tinker_cmd.go — func runTinker, func parseTinkerLine
