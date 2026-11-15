<!-- doc-tier: human | canonical-for: bp-cheatsheet | budget: 600tok -->
# bp — cheatsheet

`bp [globals] <noun> <verb> [args] [flags]`

| Command | Effect | Example |
|---|---|---|
| `bp setup` | wizard (TTY) / scripted | `bp setup --target connect --server URL --token $TOK` |
| `bp servers` / `bp use <name>` | list / switch | `bp use prod` |
| `bp whoami`/`bp capabilities` | server + auth tier / whole API, one call | `bp whoami` |
| `bp doc ls <type>`/`get`/`diff <type> <id>` | list / one doc / draft vs published, exits 1 on a difference | `bp doc diff post p1` |
| `bp doc query <type>` | filtered read | `bp doc query post --filter 'status=draft'` |
| `bp doc create <type>`/`patch`/`duplicate <type> <id>` | create / edit / copy as a draft | `bp doc patch post p1 --set title=New` |
| `bp doc mutate` | atomic batch; also `publish`/`unpublish`/`delete` | `bp doc publish post p1` |
| `bp make schema <type>` | v2 skeleton | `bp make schema product --out product.json` |
| `bp schema get/apply` | read / upsert schema | `bp schema apply --file product.json` |
| `bp schema pull/diff/push <dir>` | schema files; diff exits 1 | `bp schema diff ./schemas` |
| `bp seed <type>` | sample docs | `bp seed product --count 5 --publish` |
| `bp tinker` | authed REPL (`drafts`) | `query product` |
| `bp media ls/upload/delete` | assets; delete by file/asset id | `bp media upload a.jpg` |
| `bp workspace create/ls` | workspaces | `bp workspace create Spike` |
| `bp search query <q>` | search | `bp search query oslo` |
| `bp paper view <slug>` | render paper | `bp paper view welcome` |
| `bp task ls`/`ready`/`get`/`prime` | task board: [tasks.md](tasks.md) | `bp task ready --limit 5` |
| `bp task next`/`claim`/`close` | claim/close, CAS on the epoch | `bp task close task-101 a1 1` |
| `bp upgrade` | self-update | `bp upgrade --check` |

**Barkpark Cloud** (needs `bp login`): `bp signup` · `bp barkparks` · `bp launch` · `bp go-live` · `bp doctor` ([cloud/README](../../cloud/README.md)).

Globals: `-s/-w/-p/-d` (server/workspace/project/dataset) · `-o table|json|yaml|minimal` (json when piped) · `-q` minimal receipt · `--dry-run` preview · `--yes` confirm · `--no-retry` send once.

Body flags (after verb, write commands only): `--set k=v` / `--set k:=json` (typed) · `-f/--file -` stdin.

Exit codes: `docs/cli/error-exit-table.md`. Canon: [HANDBOOK](../cli/HANDBOOK.md).
