<!-- doc-tier: agent | canonical-for: bp-cli-overview | budget: 450tok -->
# bp CLI

Plugin-dynamic Go CLI in `internal/cli/`. The verb tree is a pure function of the server's capabilities manifest (`/v1/capabilities`); `Execute()` in cli.go dispatches a static builtins switch then manifest-driven verbs. Write bodies: declared args seed, `--set k=v` merges strings, `--set k:=json` sends TYPED values (number/bool/array/object — the server patch path stores types verbatim, no coercion), `--file`/stdin overrides all.

Dev-loop builtins (hand-rolled scoped URLs `/w/<ws>/p/<project>/v1/…`, NOT the inert flat BuildURL): `bp make schema <name>` prints a fill-the-blanks schema v2 skeleton (no network); `bp seed <type> [--count N]` fabricates draft sample docs; `bp tinker` is a query/doc/mutate REPL. Errors carry a humane `hint()` second line; the 9-code exit ladder (0–8) is unchanged.

- New builtin verb: copy the pattern in builtins.go (`runWhoami` / `runCapabilities` — `*writer` + `globals` + `manifest.Context` in, exit int out).
- `bp paper` renders Bulldocs portable-docs in the terminal via `internal/pdrender` (see docs/cards/tui.md).
- Error → exit-code mapping lives in errors.go and is specified in the canonical table below.
- `docs/cli/**` is PATH FROZEN — cli.go comments reference it; never move these files.

Canonical references:
- docs/cli/error-exit-table.md — exit codes + error-envelope mapping (canonical).
- docs/cli/m0-decisions.md — M0 decisions, incl. scoped_admin no-blanket-hide and content-addressed tier-projected ETag rules.
- docs/cli/HANDBOOK.md — operator manual (config precedence, migration semantics, safety philosophy).
- docs/cli/manifest.schema.json — manifest shape; docs/cli/fixtures/*.json are load-bearing for Go tests (manifest_test.go, cli_test.go).

## Code anchors
- internal/cli/cli.go — func Execute
- internal/cli/builtins.go — func runWhoami, func runCapabilities
- internal/cli/paper_cmd.go — func runPaper
- internal/cli/errors.go — func exitForCode, func classifyError, (apiError).hint
- internal/cli/make_cmd.go — func runMakeSchema
- internal/cli/seed_cmd.go — func runSeed, func generateDoc
- internal/cli/tinker_cmd.go — func runTinker, func parseTinkerLine
