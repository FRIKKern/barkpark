<!-- doc-tier: human | canonical-for: paper-excellence-cold-run-harness | budget: 4000tok -->

# Cold-run harness

The Paper Excellence epic closes on one unfakeable test: a **cold** agent —
no warm context, no host settings, no repo — authors a premium Paper using only
the published guide and the slice-built `bp`. A warm agent acting cold is a
vacuous green, the exact defect this epic hunts. These scripts turn the wave-7
verify round's proven commands into a committed, reproducible chain so the run
is auditable and never re-derives them.

```sh
# 1. build the bp the cold run consumes (this checkout, not a stale binary)
BP=$(bash tooling/paper-excellence/harness/build-bp.sh | tail -1)

# 2. spawn the cold agent (needs a real key — see pe-w7-hg-anthropic-key)
ANTHROPIC_API_KEY=sk-... BP_BIN_DIR=$(dirname "$BP") \
  bash tooling/paper-excellence/harness/spawn-cold.sh cold-prompt.txt run/transcript.jsonl

# 3. did the paper land on the server?
bash tooling/paper-excellence/harness/landed-check.sh <the-run's-slug>

# 4. width-check it: live paper -> rig fixture -> hermetic photograph
bash tooling/paper-excellence/harness/fixture-from-live.sh <the-run's-slug>
#   (prints the SHOT_WIDTHS='1920,1280,768' rig/gate.sh command to run next)

# 5. did the agent stay cold? audit the transcript for leaks
bash tooling/paper-excellence/harness/leakage-audit.sh run/transcript.jsonl
```

## Each script + the proof row it encodes

| script | what it does | proof ledger row |
|---|---|---|
| `build-bp.sh` | `CGO_ENABLED=0 CC=/usr/bin/clang go build -o bp ./cmd/barkpark` + a `bp version` smoke. Encodes two traps: the repo root has no `main` package (build `./cmd/barkpark`), and `cc` is a claude-wrapper alias that shadows the compiler. | `pe-w7-slice-binary-scaffold-proof` |
| `spawn-cold.sh` | `env -i` + scratch `HOME`/`XDG_CONFIG_HOME` + minimal 5-field bp config + cwd outside the repo + `claude --bare --setting-sources '' --model <explicit>`. Keychain OAuth is dead under `--bare`/fresh HOME, so `ANTHROPIC_API_KEY` is required — absent, it fails loud naming `pe-w7-hg-anthropic-key`. | `pe-w7-cold-harness` spawn row |
| `landed-check.sh` | D47 existence probe: POST the bulldocs `/sync` arm with valid BPML + `baseRev "1"`; `not_found` present ⇒ NOT landed (exit 1), absent ⇒ landed (exit 0). Verdict is the error code, never an HTTP status. | `pe-w7-cold-harness` D47 row |
| `fixture-from-live.sh` | `bp doc get paper <slug>` → the rig's `fetch-fixtures` transform → a scratch fixture → prints the `SHOT_WIDTHS='1920,1280,768' rig/gate.sh` command. Binds the live store to the hermetic width-law rig. | `pe-w7-rig-binding-proof` |
| `leakage-audit.sh` | Derives the sanctioned-read allowlist FROM THE LIVE GUIDE at run time, scans a transcript's `bp` calls (bare AND path-prefixed — the cold prompt hands the agent the binary's absolute path), fails on any read outside `{guide slug} ∪ allowlist ∪ {the agent's own created/pushed slug(s), D50} ∪ {capabilities, doc ls tag}`; `bp search` / `bp task` are hard fails. `--selftest` proves it can lose, per spelling class. | `pe-w7-cold-harness` leakage row |
| `probe-no-key.jsonl` | The committed no-key spawn probe: 3 genuine lines from a real invalid-key run — `system/init` (`apiKeySource: ANTHROPIC_API_KEY`, `model: claude-opus-5`), `system/api_retry` (`authentication_failed`, `401`), `result/error_during_execution`. Auth-fail is the EXPECTED outcome; it proves the launch and that the stream parses, at zero token cost. | `pe-w7-cold-harness` spawn row |

## Why each proof is real (mutation-provable)

- **`landed-check.sh`** was run both ways against live guerrilla: an absent slug
  (`pe-w7-cold-run-paper`) exited 1, a present slug (`paper-authoring-excellence`)
  exited 0. The default slug is the cold run's product — absent until the run
  publishes it — so a bare invocation exits 1 today and flips to 0 after the run.
- **`leakage-audit.sh --selftest`** runs a built-in leaky transcript (a
  `bp search` + a read of an un-sanctioned slug) and asserts it FAILS, and a
  clean transcript and asserts it PASSES. An audit that cannot fail is not one.
- **`build-bp.sh`** builds and smokes `bp version` locally.
- **`spawn-cold.sh`** with the key unset exits 3 with the loud
  `pe-w7-hg-anthropic-key` message; `probe-no-key.jsonl` is the real stream from
  a launched-but-auth-failed run.

## Hermetic boundary

Only `spawn-cold.sh`, `landed-check.sh`, `fixture-from-live.sh`, and
`leakage-audit.sh`'s guide fetch touch the network — the same one-networked-step
discipline as `rig/fetch-fixtures.sh`. The width-law gate they hand off to
(`rig/gate.sh`) stays fully hermetic: no server, no database, no network.

The built binary lands in `.bin/` (gitignored — never commit the Go binary).
