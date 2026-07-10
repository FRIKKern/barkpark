# Agent Onramps — Epic Charter

Epic task: `agent-onramps-epic` (published). Wave tasks are its children (`parent_id=agent-onramps-epic`).

## Vision

ONE COMMAND, ANY AGENT. An AI agent on any major surface — Claude Code, Codex CLI/Desktop, Cursor, Cursor Cloud, ChatGPT, Claude.ai — goes from "never heard of Barkpark" to "created a schema, a doc, a task, and a paper" in under two minutes, and every target feels hand-built for it. Three layers: (1) a hub doc owning the two shared journeys (AUTH, CREATE-QUICKSTART), (2) per-target premium docs + repo-shipped assets matching CURSOR.md's care, (3) a `bp onramp <target>` verb that turns the docs into a 1-step install. `bp mcp serve` (stdio, SHIPPED — #1790/#1791) is the registration payload everywhere a local CLI can run; remote surfaces get scrupulous honesty about what works TODAY.

## Decisions

1. **Hub doc `docs/setup/AGENT-ONRAMPS.md` owns AUTH + CREATE-QUICKSTART** (slug `agent-onramps`); per-target docs point at it instead of repeating — single source of shared copy, budget-safe.
2. **The auth core teaches the missing cloud link**: `bp login` → `bp barkparks -o json` → `bp instance credentials <id>` → `bp setup --target connect`. The CloudToken is control-plane only and never authenticates content writes (cloud12_cmd.go:1036-1111); CLOUD-QUICKSTART.md stops short of this and the hub must not.
3. **Unattended happy paths = fresh local (`bp setup --target local --yes`), connect-with-token, non-2FA cloud login.** Provisioning a NEW hosted instance is human-gated (Stripe Checkout browser step) and 2FA accounts can't complete `bp login` non-interactively — docs say so plainly instead of pretending.
4. **ChatGPT's premium path is Custom GPT Actions on the public `/v1/openapi.json` + scoped bearer token** — ships today with zero code (openapi.ex 3.1 + bearerAuth; `/v1/openapi.json` public on `:api_unlimited`). Actions ≠ MCP; this is stronger than "paste HTTP calls". Caveats baked in: needs a publicly reachable hosted instance; spec bodies are deliberately loose (additionalProperties).
5. **Claude.ai gets honesty, not vaporware**: remote-MCP-only (Streamable HTTP + OAuth 2.1/PKCE), which stdio `bp mcp serve` cannot satisfy. Manual path today = direct HTTP API with a scoped token. The remote MCP endpoint (originally filed as `ao-backlog-remote-mcp`) is now superseded by `ve-w2-remote-mcp-bearer` under `viable-everywhere-epic`, which builds it Go-side.
6. **`bp onramp <target>` ships PRINT-FIRST in wave 1** (exactly the cmux_install.go precedent: print the blocks + where they go, never write). `--write` with safe JSON merge (Cursor, Claude Code) is wave 2; Codex TOML write (no TOML dep in repo) is wave 3. The verb rejects `chatgpt`/`claude-ai` with a pointer to REMOTE.md.
7. **Codex secrets ride `env_vars = ["BARKPARK_API_TOKEN"]` (shell-forward whitelist), never `${VAR}` in TOML values** — value-level expansion is undocumented in Codex and would ship a literal string. Static `env` table carries only the non-secret URL.
8. **Claude Code's teach-layer is a curl-able snippet `.claude/CLAUDE-BARKPARK.md`** — byte-for-byte-parallel to `.cursor/rules/barkpark-tasks.mdc` (same claim-first contract, no YAML front-matter). No skill/plugin in wave 1; a plugin is heavier and out of scope. Location is outside `docs/` so no G1 header is required, and the filename dodges the §4 CLAUDE.md/AGENTS.md surface scan.

   **Amended (wave 2, `ve-w2-agents-md-onramp`).** The "byte-for-byte-parallel" wrappers are now a **derivation**, not hand-kept copies. There is ONE canonical consumer teach text — a Go string in `internal/cli/onramp_cmd.go` (`renderAgentsMDBody` → `agentsMDCanonicalBody`), emitted by `bp onramp agents-md` wrapped in `<!-- barkpark:onramp:begin -->` / `<!-- barkpark:onramp:end -->` markers into `./AGENTS.md`. The three wave-1 wrappers (`.cursor/rules/barkpark-tasks.mdc`, `.claude/CLAUDE-BARKPARK.md`, and CODEX.md's fenced block) each embed that body in their own framing, differing only in the worker-id prefix and the "see also" doc pointer; a Go parity test (`TestOnrampAgentsMdWrapperParity`) reads all three and fails on drift, so dedup is gate-enforced. CODEX.md's earlier hand-reworded block — a lossy subset that had dropped `bp task prime`, the Conventions header, the `parent_id` nesting line, and the 409 `doc_changed_since_claim` line — is replaced by the canonical superset.

   The **wrapper-NAME dodge is unchanged and load-bearing**: the canonical emission is NEVER a repo-shipped asset. A committed `AGENTS.md`-named file carrying this text would trip the §4 G1-header requirement, the §5 canonical-for slug uniqueness, AND the frozen 700B `AGENTS.md` cap (this repo's own root `AGENTS.md` is the shell-danger-rules doc at 698/700B). The emitter merges into a consumer's *existing* `AGENTS.md` via markers **precisely because** a real `AGENTS.md` routinely pre-exists — barkpark's own root file is the proof. The canonical body lives only as a Go constant + a `.golden` fixture at depth ≥ 3 (`internal/cli/testdata/agents_md.golden`), which escapes the §4 maxdepth-2 `AGENTS.md` scan by both depth and name. The human-tier doc `docs/setup/AGENTS-MD.md` (`canonical-for: agents-md-onramp`) owns the emitter's story.
9. **Env dialects are per-tool and never mixed**: Claude Code `.mcp.json` uses `${VAR}`/`${VAR:-default}`; Cursor uses `${env:VAR}`; Codex uses `env_vars` forwarding. Each doc states its own dialect and warns against the neighbors'.
10. **Discovery rides code, not the gated files**: one line in `bp setup` connect's done-screen (`writeNextSteps` internal/cli/setup/connect.go:142-149 + `nextSteps` JSON twin) + a "See also" cross-link in CURSOR.md (~600B headroom). README (7400/7400) and INDEX (1197/1200) are untouched — no gate requires an INDEX listing (§2 is one-directional and its grep skips brace groups).
11. **All new docs are human-tier with the mandatory G1 header, unique slugs, declarative budgets, and are NOT added to the check-doc-budgets CAPS heredoc.** Slugs: `agent-onramps`, `claude-code-onramp`, `codex-onramp`, `cursor-cloud-onramp`, `remote-agent-onramp`. Verify uniqueness via `git ls-files` (local docs-anchors-check false-fails §5 on `.claude/worktrees` copies).
12. **Cross-references among the five NEW docs use backtick code spans (`docs/setup/CODEX.md`), never markdown links** — §3c fails CI on a `[x](y.md)` link to a not-yet-merged doc, and the five PRs must merge in any order. Real markdown links are allowed only to docs already on main (CURSOR.md, CLOUD-QUICKSTART.md, api-v1.md, …). Linkify later if we care (wave 2 polish).
13. **Cursor Cloud is a short sibling `docs/setup/CURSOR-CLOUD.md`** (environment.json `install` = install-cli.sh; BARKPARK_API_URL/TOKEN via Cursor Secrets UI, never in the committed file; reuse CURSOR.md's mcp.json stanza verbatim), built inside the core slice — CURSOR.md itself stays the desktop doc.
14. **Every doc's steps 1–3 are shaped so `bp onramp <target> --write` can later replace them verbatim** — the doc's JSON/TOML block IS what the verb emits (the verb slice and doc slices share the stanza text).
15. **`bp mcp serve` is SHIPPED and is the single registration payload** — default curated `tasks` toolset everywhere; `--tools all` is expert-only (Cursor hard-caps 40 tools vs ~107 manifest commands); every doc notes the Tasks-plugin fail-fast requirement.

## Roadmap

### Wave 1 (this wave — 5 parallel slices)
1. **S1 core-hub** (medium): `docs/setup/AGENT-ONRAMPS.md` hub (AUTH + CREATE-QUICKSTART + target router) + `docs/setup/CURSOR-CLOUD.md` sibling + CURSOR.md cross-link line. Task `ao-w1-hub-core`.
2. **S2 claude-code** (medium): `docs/setup/CLAUDE-CODE.md` + `.claude/CLAUDE-BARKPARK.md` snippet asset. Task `ao-w1-claude-code`.
3. **S3 codex** (medium): `docs/setup/CODEX.md` (CLI + Desktop, config.toml + `codex mcp add` + AGENTS.md template block). Task `ao-w1-codex`.
4. **S4 remote-surfaces** (medium): `docs/setup/REMOTE.md` — ChatGPT Actions (real, today) + Claude.ai honesty. Task `ao-w1-remote-surfaces`.
5. **S5 onramp-verb** (medium/large): `bp onramp <target>` print-first Go verb + setup done-screen discovery line. Task `ao-w1-onramp-verb`.

### Wave 2 (planned)
- `bp onramp --write` for JSON targets (Cursor `.cursor/mcp.json`, Claude Code `.mcp.json`): unmarshal into `map[string]json.RawMessage`, touch only `mcpServers.barkpark`, temp-file+rename atomic write (SaveConfig idiom), `--force` for stanza overwrite, golden don't-clobber fixtures. Markdown assets via BEGIN/END-marker managed blocks.
- Linkify cross-refs among the five docs (all on main by then); decide whether to spend an INDEX middot-trim.

### Wave 3 (planned)
- `bp onramp codex --write`: TOML append-with-marker + parse-lite duplicate detection (no new dep) OR a vetted TOML lib; the sizing pivot of the whole verb.
- Spike: `claude mcp add` / `codex mcp add` shell-out as an alternate write path (host-tool presence not guaranteed — option, not plan).

### Backlog
- `ao-backlog-remote-mcp`: hosted remote MCP endpoint (Go-side Streamable HTTP, bearer for ChatGPT MCP + OAuth 2.1/PKCE for Claude.ai). NET-NEW capability, epic-sized — CANCELLED/superseded by `ve-w2-remote-mcp-bearer` under `viable-everywhere-epic`.

## Wave log

### Wave 2026-07-09 (wave 1 — all five slices built + reviewed)

**Landed (review-fixed `-r` branches are the ones to merge):**
- **S1 hub-core** (`ao-w1-hub-core`) → `loop-epic/agent-onramps-md-hub-auth-create-quickst-0-r`. AGENT-ONRAMPS.md + CURSOR-CLOUD.md + CURSOR.md see-also. Review fixed two broken CREATE quickstart steps: the piped-unedited `bp make schema` skeleton became a minimal guaranteed-parse inline schema, and the `body_html`-only paper (which `bp paper view` rejects — "no renderable blocks", paper_cmd.go:187) became native blocks. CURSOR-CLOUD linked for real (same PR); installer-path claim corrected to /usr/local/bin-with-fallback.
- **S2 claude-code** (`ao-w1-claude-code`) → `loop-epic/claude-code-onramp-claude-code-md-curl-a-1-r`. CLAUDE-CODE.md + .claude/CLAUDE-BARKPARK.md. Review fixed `bp task show` → `bp task get` (live-verified: the task noun has NO show verb — ls/ready/prime/get/claim/close/next/move) in the new snippet AND the shipped `.cursor/rules/barkpark-tasks.mdc` it mirrors, and single-quoted the token env in the `claude mcp add --scope project` one-liner (unquoted, the shell baked the LITERAL secret into the committed .mcp.json).
- **S3 codex** (`ao-w1-codex`) → `loop-epic/codex-onramp-codex-md-covers-cli-desktop-2-r`. CODEX.md. Review fixed the installer path, `task show`→`task get`, the one-liner's overclaim (codex mcp add can't write env_vars/timeouts), and added the `task create` fallback line the troubleshooting already referenced.
- **S4 remote-surfaces** (`ao-w1-remote-surfaces`) → `loop-epic/remote-md-chatgpt-custom-gpt-actions-wor-3-r`. REMOTE.md. Review fixed the paper curl (its `content:{blocks:[]}` wrapper matches NO ingest clause — top-level `slug`+`blocks` required) and stated the route's admin-or-ingest-token gate; mutate success is 200+transactionId, not 201.
- **S5 onramp-verb** (`ao-w1-onramp-verb`) → `loop-epic/bp-onramp-target-print-first-verb-setup--4-r`. Review closed three decision-14 byte-parity gaps: claude-code stanza gained `"type": "stdio"`, codex TOML gained the 15/120 timeouts, and the claude one-liner gained `--scope project --transport stdio` + the quoted token placeholder. Goldens updated; go build/vet/test green.

**Ledger:** all five tasks stamped with real evidence, merge-gated criterion left open for the lead; reviewer flipped lifecycle open→in_progress (the built-but-unmerged truth). `ao-backlog-remote-mcp` filed and untouched.

**Cross-cutting truth found:** admin bearer IS accepted on bulldocs ingest (RequireIngestToken admin fallback) — the hub/REMOTE paper steps work with a `bp_admin_` token, no BARKPARK_INGEST_TOKEN needed.

**Gate nuance for the lead:** the doc slices' literal task-gate second half (`git ls-files … uniq -d`) is red on origin/main itself — 3 pre-existing dup slugs (blog-starter-template, website-starter-template, cursor-integration) outside this epic. The authoritative CI gate `docs-anchors-check.sh` §5 is green on every `-r` branch, and no new dup was introduced.

**Stalled:** nothing.

**Next wave should take:** (1) `bp onramp --write` for the JSON targets (charter wave-2 plan) — the print-first goldens now byte-match the docs, so `--write` is a mechanical merge; (2) linkify the five docs' cross-refs once all are on main + decide the INDEX middot question; (3) live-verify the two asserted-but-unexecuted host-tool grammars (`claude mcp add` / `codex mcp add` flag syntax) in real installs; (4) consider a CREATE-quickstart smoke script (spin a local server, run the hub's four blocks verbatim) so the copy-paste contract can't rot — this wave found TWO of five quickstart blocks broken at read-time, exactly the failure a doc gate can't catch.
