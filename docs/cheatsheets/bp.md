<!-- doc-tier: human | canonical-for: bp-cheatsheet | budget: 600tok -->
# bp — cheatsheet

```
bp [globals] <noun> <verb> [args] [flags]
```

| Command | Effect | Example |
|---|---|---|
| `bp setup` | wizard (TTY) / scripted via `--target` | `bp setup --target connect --server URL --token $TOKEN` |
| `bp servers` / `bp use <name>` | list / switch saved servers | `bp use prod` |
| `bp whoami` | active server + auth tier | `bp whoami` |
| `bp capabilities` | the whole API surface, one call | `bp capabilities -o json` |
| `bp doc ls <type>` | list documents | `bp doc ls post --limit 10` |
| `bp doc get <type> <id>` | one document | `bp doc get post p1 --perspective drafts` |
| `bp doc query <type>` | filtered read | `bp doc query post --query 'status=="published"'` |
| `bp doc mutate` | atomic batch (create/patch/publish/…) | `bp doc mutate --file muts.json` |
| `bp schema get/apply` | read / upsert a schema | `bp schema apply --file post.json` |
| `bp media ls/upload` | assets | `bp media upload photo.jpg` |
| `bp search query <q>` | full-text search | `bp search query norway --engine indx` |
| `bp paper view <slug>` | render a paper in the terminal | `bp paper view welcome --theme dark` |
| `bp migrate <from> <to>` | copy docs between saved servers | `bp migrate prod local --type post --yes` |
| `bp upgrade` | self-update from `cli-v*` releases | `bp upgrade --check` (exit 1 when behind) |
| `bp uninstall` | remove config; `--local` adds dev stack | `bp uninstall --local --dry-run` |

Globals: `-s/-w/-p/-d` (server/workspace/project/dataset) · `-o table|json|yaml|minimal` (json auto when piped) · `-q` minimal receipt · `--dry-run` client-side preview · `--yes` confirm destructive · `--file -` reads stdin.

Exit codes: `docs/cli/error-exit-table.md` (0 ok · 2 usage · 3 auth · 4 not-found · 5 validation · 6 conflict).

Canon: [`../cli/HANDBOOK.md`](../cli/HANDBOOK.md).
