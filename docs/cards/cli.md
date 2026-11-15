<!-- doc-tier: agent | canonical-for: bp-cli-overview | budget: 450tok -->
# bp CLI

Plugin-dynamic Go CLI in `internal/cli/`; verbs from the manifest (`/v1/capabilities`); `Execute()` (cli.go) runs builtins first. Write bodies: declared args seed, `--set k=v` merges strings, `--set k:=json` sends TYPED JSON verbatim, `--file`/stdin overrides all bar a declared body arg (`bulldocs publish <slug>`), merged over it. Write verbs (`doc create/patch/delete/publish/unpublish`) ride manifest `mutation_op`+`set_key` → `{mutations:[{op:…}]}` (buildBody). `--set` merges SHALLOW into `content` (`--set 'blocks:=[…]'`); a dotted key and `content:={…}` are REFUSED; `k:=null` on `doc patch` DELETES k.

Builtins (scoped `/w/<ws>/p/<proj>/v1/…` URLs, not BuildURL): `bp make schema <name>` prints a v2 skeleton; `bp schema pull|diff|push <dir>`: schema files; `bp doc diff|duplicate <type> <id>`: draft vs published | copy as a draft; `bp make workflow <site>` prints the Actions builder template; `bp seed <type>` fakes drafts; `bp tinker`: query/mutate REPL.

**Scaffy catalog-first**: check `scaffy/commands/` before hand-editing a repeated shape → scaffy/README.md.

- Full-screen: `bp paper`, `bp tasks` → docs/cards/tui.md.
- Credentials → docs/auth.md: `bp token create --permissions …,admin`; no admin locally: `bp instance admin-token <id> --install`; attach a box to Cloud: `bp barkparks adopt` → deploy/README.md.
- Support desk: `bp ticket` (inbox·show·answer·close) + `bp ticket-key` (mint·ls·rotate·pause·unpause·revoke) → docs/contracts/plugin-http-api.md.
- `docs/cli/**` is PATH FROZEN (cli.go refs it): {error-exit-table,m0-decisions,HANDBOOK}.md, manifest.schema.json + fixtures/*.json.
- Go gate, LOCAL: `CGO_ENABLED=0 go build ./... && go vet ./internal/{cli,manifest}/... && go test ./internal/{cli,manifest}/...`; CI runs `./...` on Linux.

## Code anchors
- internal/cli/cli.go — func Execute
- internal/cli/builtins.go — func runWhoami, func runCapabilities
- internal/cli/paper_cmd.go — func runPaper
- internal/cli/errors.go — codeExit (paper_exists: 6), classifyError, hint
- internal/cli/make_cmd.go — func runMakeSchema
- internal/cli/make_workflow.go — func renderDeployWorkflow, func runMakeWorkflow
- internal/cli/seed_cmd.go — func runSeed, func generateDoc
- internal/cli/tinker_cmd.go — func runTinker, func parseTinkerLine
