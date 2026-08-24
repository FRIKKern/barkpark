<!-- doc-tier: human | canonical-for: agents-md-onramp | budget: 900tok -->
# AGENTS.md — the one teach block

`AGENTS.md` is the tool-agnostic convergence standard (~two dozen agents read it: Codex, Aider, and a growing list). One file at your repo root, and any of them knows the Barkpark claim-first contract before it touches the board. `bp onramp agents-md` emits that block — the ONE canonical teach text — so you never hand-copy it.

**Register the movement** — every unit of work runs under a claimed `bp` task: claim before you work, stamp evidence as you prove it, close on the claim epoch. The full doctrine, and the three ways a registration silently does not happen, is in [Agent Onramps](AGENT-ONRAMPS.md).

## Emit it

```bash
bp onramp agents-md
```

By default it prints the block and where it belongs (`./AGENTS.md`) — paste it into your repo-root `AGENTS.md`, or add `--write` to merge it for you ([Merge semantics](#merge-semantics---write)). Machine-readable form:

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

Those markers exist because a consumer's `AGENTS.md` **routinely already exists** — this repo's own root `AGENTS.md` is the proof (it holds shell-danger rules, not Barkpark teach text). The block is emitter output for *your* repo, never a Barkpark-committed asset; the markers are how a `--write` re-run refreshes only its own block.

## One body, three framings

The block is the single source of truth. Three teach wrappers **derive** from it — same body, each in its tool's framing, differing only in the worker-id prefix and the "see also" pointer:

| File | Framing | Its two lines |
|---|---|---|
| `.cursor/rules/barkpark-tasks.mdc` | `.mdc` front-matter | worker id `cursor-…` · footer → `CURSOR.md` |
| `.claude/CLAUDE-BARKPARK.md` | `# Barkpark tasks` H1 | worker id `claude-…` · footer → `CLAUDE-CODE.md` |
| `CODEX.md` block | fenced `markdown` | the canonical `<tool>-…` rendering verbatim |

Two Go gates read all three and fail if any stops embedding the canonical body or drops the doctrine (`TestOnrampAgentsMdWrapperParity`, `TestDoctrineOnEveryPrimingSurface`) — dedup is enforced, not hoped for.

## Merge semantics (`--write`)

`bp onramp agents-md --write` rides the shared writer seam (atomic temp-file+rename, as every JSON target) and merges the marker-managed block into `./AGENTS.md`:

- **no file** → create it with the block (`created`).
- **file, no markers** → *append* the block after a blank line (`updated`); existing content is preserved byte-for-byte, never rewritten.
- **markers present, block differs** → left untouched (`skipped`); `--force` refreshes only the text between the markers, leaving your surrounding content put.
- **markers present, block identical** → `unchanged`, exit 0, file byte-untouched.

```bash
bp onramp agents-md --write            # merge (safe, idempotent)
bp onramp agents-md --write --force    # refresh a stale managed block in place
```

Every run prints a per-file action (`created` / `updated` / `unchanged` / `skipped`), in text and under `-o json` — the same vocabulary as the JSON `--write` targets.

## See also

- [Agent Onramps hub](AGENT-ONRAMPS.md) — the doctrine, the shared AUTH + CREATE journeys, every per-target onramp.
- [Codex](CODEX.md) — the AGENTS.md-reading agent this block was first shaped for.
