<!-- doc-tier: human | canonical-for: bp-cheatsheet | budget: 600tok -->
# bp — cheatsheet

```
bp [globals] <noun> <verb> [args] [flags]
```

| Command | Effect | Example |
|---|---|---|
| `bp setup` | wizard (TTY) / scripted | `bp setup --target connect --server URL --token $TOK` |
| `bp servers` / `bp use <name>` | list / switch servers | `bp use prod` |
| `bp whoami` | active server + auth tier | `bp whoami` |
| `bp capabilities` | the whole API surface, one call | `bp capabilities` |
| `bp doc ls <type>` | list documents | `bp doc ls post` |
| `bp doc get <type> <id>` | one doc | `bp doc get post p1` |
| `bp doc query <type>` | filtered read | `bp doc query post --filter 'status=draft'` |
| `bp doc create <type>`/`patch <type> <id>` | write / edit one document | `bp doc patch post p1 --set title=New` |
| `bp doc mutate` | atomic batch; also `publish`/`unpublish`/`delete` | `bp doc publish post p1` |
| `bp make schema <type>` | v2 skeleton — edit before applying | `bp make schema product --out product.json` |
| `bp schema get/apply` | read / upsert schema | `bp schema apply --file product.json` |
| `bp seed <type>` | schema-valid sample docs | `bp seed product --count 5 --publish` |
| `bp tinker` | authed REPL (`drafts`) | `query product` |
| `bp media ls/upload` | assets | `bp media upload a.jpg` |
| `bp workspace create/ls` | sandbox workspace | `bp workspace create Spike` |
| `bp search query <q>` | full-text search | `bp search query oslo` |
| `bp paper view <slug>` | render a paper | `bp paper view welcome` |
| `bp task ls`/`ready`/`get`/`prime` | the task board — full surface in [`tasks.md`](tasks.md) | `bp task ready --limit 5` |
| `bp task next`/`claim`/`close` | claim/close, CAS on the epoch | `bp task close task-101 a1 1` |
| `bp upgrade` | self-update from `cli-v*` | `bp upgrade --check` |

**Barkpark Cloud** (needs `bp login`): `bp signup` · `bp barkparks` · `bp launch` · `bp go-live` · `bp doctor` — see [cloud/README](../../cloud/README.md).

Globals: `-s/-w/-p/-d` (server/workspace/project/dataset) · `-o table|json|yaml|minimal` (json when piped) · `-q` minimal receipt · `--dry-run` preview · `--yes` confirm.

Body flags (after verb, write commands only): `--set k=v` / `--set k:=json` (typed) · `-f/--file -` stdin.

Exit codes: `docs/cli/error-exit-table.md`.

Canon: [`../cli/HANDBOOK.md`](../cli/HANDBOOK.md).
