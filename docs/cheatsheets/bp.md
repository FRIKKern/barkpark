<!-- doc-tier: human | canonical-for: bp-cheatsheet | budget: 600tok -->
# bp — cheatsheet

```
bp [globals] <noun> <verb> [args] [flags]
```

| Command | Effect | Example |
|---|---|---|
| `bp setup` | wizard (TTY) / scripted | `bp setup --target connect --server URL --token $TOKEN` |
| `bp servers` / `bp use <name>` | list / switch saved servers | `bp use prod` |
| `bp whoami` | active server + auth tier | `bp whoami` |
| `bp capabilities` | the whole API surface, one call | `bp capabilities` |
| `bp doc ls <type>` | list documents | `bp doc ls post` |
| `bp doc get <type> <id>` | one document | `bp doc get post p1` |
| `bp doc query <type>` | filtered read | `bp doc query post --filter 'status=draft' --perspective raw` |
| `bp doc mutate` | atomic batch; or ergonomic `publish`/`unpublish`/`delete <type> <id>` | `bp doc publish post p1` |
| `bp schema get/apply` | read / upsert schema | `bp schema apply --file post.json` |
| `bp media ls/upload` | assets | `bp media upload photo.jpg` |
| `bp workspace create/ls` | sandbox workspace | `bp workspace create Spike` |
| `bp search query <q>` | full-text search | `bp search query norway` |
| `bp paper view <slug>` | render a paper | `bp paper view welcome` |
| `bp task ls` / `ready` | all / claimable tasks | `bp task ready --limit 5` |
| `bp task prime` | agent rehydration, one call | `bp task prime --worker a1` |
| `bp task next <worker>` | claim the NEXT ready task | `bp task next a1` |
| `bp task get <id>` | task + child rail | `bp task get task-101` |
| `bp task claim <id> <worker>` | fenced claim | `--resources a.go,b.go` fences files |
| `bp task close <id> <worker> <epoch>` | close, CAS on epoch | `bp task close task-101 a1 1` |
| `bp upgrade` | self-update from `cli-v*` releases | `bp upgrade --check` |

**Barkpark Cloud** (needs `bp login`): `bp signup` · `bp barkparks` · `bp launch` · `bp go-live` · `bp doctor` — see [cloud/README](../../cloud/README.md).

Globals: `-s/-w/-p/-d` (server/workspace/project/dataset) · `-o table|json|yaml|minimal` (json when piped) · `-q` minimal receipt · `--dry-run` preview · `--yes` confirm.

Body flags (after verb, write commands only): `--set k=v` / `--set k:=json` (typed) · `-f/--file -` stdin.

Exit codes: `docs/cli/error-exit-table.md`.

Canon: [`../cli/HANDBOOK.md`](../cli/HANDBOOK.md) · tasks: [`tasks.md`](tasks.md).
