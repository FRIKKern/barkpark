<!-- doc-tier: human | canonical-for: agents-md-onramp | budget: 1600tok -->
# AGENTS.md — the one teach block

`AGENTS.md` is the tool-agnostic convergence standard (~two dozen agents read it: Codex, Aider, and a growing list). One file at your repo root, and any of them knows the Barkpark claim-first task contract before it touches the board. `bp onramp agents-md` emits that block — the ONE canonical teach text — so you never hand-copy it.

## Emit it

```bash
bp onramp agents-md
```

Print-only in this wave: it shows the block and where it belongs (`./AGENTS.md`); nothing is written for you yet. Pipe or paste it into your repo-root `AGENTS.md`. Machine-readable form for scripts:

```bash
bp onramp agents-md -o json   # {target, files:[{path:"./AGENTS.md", content}], verify}
```

The block is wrapped in managed markers:

```markdown
<!-- barkpark:onramp:begin -->
## Task tracking — Barkpark (bp)
…the canonical body…
<!-- barkpark:onramp:end -->
```

Those markers exist because a consumer's `AGENTS.md` **routinely already exists** — this repo's own root `AGENTS.md` is the proof (it holds shell-danger rules, not Barkpark teach text). The block is emitter output for *your* repo, never a Barkpark-committed asset. When `--write` lands (see below), the markers are how a re-run finds and refreshes only its own block, never your surrounding content.

## One body, three framings

The block is the single source of truth. Three wave-1 teach wrappers now **derive** from it — same body, each in its tool's native framing, differing only in the worker-id prefix and the "see also" doc pointer:

| File | Framing | Its two lines |
|---|---|---|
| `.cursor/rules/barkpark-tasks.mdc` | `.mdc` front-matter | worker id `cursor-…` · footer → `docs/setup/CURSOR.md` |
| `.claude/CLAUDE-BARKPARK.md` | `# Barkpark tasks` H1 | worker id `claude-…` · footer → `docs/setup/CLAUDE-CODE.md` |
| `docs/setup/CODEX.md` block | fenced `markdown` | the canonical `<tool>-…` rendering verbatim |

A Go parity test (`internal/cli/onramp_cmd_test.go` · `TestOnrampAgentsMdWrapperParity`) reads all three and fails if any stops embedding the canonical body — dedup is gate-enforced, not a hope.

## Merge semantics (`--write`, planned)

`bp onramp agents-md --write` rides the shared onramp writer seam and merges into `./AGENTS.md`:

- **no file** → create it with the block (`created`).
- **file, no markers** → *append* the block (`updated`); your existing content is never rewritten.
- **markers present** → replace only the text between them (`updated`).
- **identical** → report `unchanged`, exit 0.

Every run prints a per-file action (`created` / `updated` / `unchanged`), in text and under `-o json` — the same action vocabulary as the JSON `--write` targets ([Agent Onramps hub](AGENT-ONRAMPS.md)). Until that ships, use the print-only path above.

## See also

- [Agent Onramps hub](AGENT-ONRAMPS.md) — the shared AUTH + CREATE journeys and every per-target onramp.
- [Codex](CODEX.md) — the AGENTS.md-reading agent this block was first shaped for.
