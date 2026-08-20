<!-- doc-tier: human | canonical-for: agents-md-onramp | budget: 900tok -->
# AGENTS.md — the one teach block

`AGENTS.md` is the tool-agnostic convergence standard (~two dozen agents read it: Codex, Aider, and a growing list). One file at your repo root, and any of them knows the Barkpark claim-first task contract before it touches the board. `bp onramp agents-md` emits that block — the ONE canonical teach text — so you never hand-copy it.

## Emit it

```bash
bp onramp agents-md
```

By default it prints the block and where it belongs (`./AGENTS.md`) — pipe or paste it into your repo-root `AGENTS.md`, or add `--write` to have it merge the block for you (see [Merge semantics](#merge-semantics---write) below). Machine-readable form for scripts:

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

Those markers exist because a consumer's `AGENTS.md` **routinely already exists** — this repo's own root `AGENTS.md` is the proof (it holds shell-danger rules, not Barkpark teach text). The block is emitter output for *your* repo, never a Barkpark-committed asset. With `--write` (see [Merge semantics](#merge-semantics---write)), the markers are how a re-run finds and refreshes only its own block, never your surrounding content.

## One body, three framings

The block is the single source of truth. Three wave-1 teach wrappers now **derive** from it — same body, each in its tool's native framing, differing only in the worker-id prefix and the "see also" doc pointer:

| File | Framing | Its two lines |
|---|---|---|
| `.cursor/rules/barkpark-tasks.mdc` | `.mdc` front-matter | worker id `cursor-…` · footer → `docs/setup/CURSOR.md` |
| `.claude/CLAUDE-BARKPARK.md` | `# Barkpark tasks` H1 | worker id `claude-…` · footer → `docs/setup/CLAUDE-CODE.md` |
| `docs/setup/CODEX.md` block | fenced `markdown` | the canonical `<tool>-…` rendering verbatim |

A Go parity test (`internal/cli/onramp_cmd_test.go` · `TestOnrampAgentsMdWrapperParity`) reads all three and fails if any stops embedding the canonical body — dedup is gate-enforced, not a hope.

## Merge semantics (`--write`)

`bp onramp agents-md --write` rides the shared onramp writer seam (the same atomic temp-file+rename as every JSON target) and merges the marker-managed block into `./AGENTS.md`:

- **no file** → create it with the block (`created`).
- **file, no markers** → *append* the block after a blank line (`updated`); your existing content is preserved byte-for-byte, never rewritten.
- **markers present, block differs** → left untouched (`skipped`); re-run with `--force` to refresh only the text between the markers — your surrounding content stays put.
- **markers present, block identical** → `unchanged`, exit 0, file byte-untouched.

```bash
bp onramp agents-md --write            # merge (safe, idempotent)
bp onramp agents-md --write --force    # refresh a stale managed block in place
```

Every run prints a per-file action (`created` / `updated` / `unchanged` / `skipped`), in text and under `-o json` — the same action vocabulary as the JSON `--write` targets ([Agent Onramps hub](AGENT-ONRAMPS.md)).

## See also

- [Agent Onramps hub](AGENT-ONRAMPS.md) — the shared AUTH + CREATE journeys and every per-target onramp.
- [Codex](CODEX.md) — the AGENTS.md-reading agent this block was first shaped for.
