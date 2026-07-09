# VIABLE EVERYWHERE — epic charter

Epic task: `viable-everywhere-epic` (published). Strategy Paper: `viable-everywhere-strategy` (guerrilla, wave 1).

## Vision

Barkpark reachable from any AI surface in under two minutes, always via the mechanism that surface NATIVELY speaks, never promising a connector the surface doesn't ship. The doctrine spine is MECHANISM CLASSES, not per-surface bespoke work — the marginal cost of each new surface trends to zero:

- **Class A — local stdio MCP**: `bp mcp serve` + one `bp onramp <target>` per surface. Built, compounding, near-zero marginal cost for `mcpServers`-dialect surfaces.
- **Class B — rules/instructions files**: one canonical consumer-facing AGENTS.md emission. Net-new; covers ~20+ coding agents including the only path to Aider.
- **Class C — OpenAPI actions**: public `/v1/openapi.json` → ChatGPT Custom GPT Actions. Built, works today, and remains the only WRITE path for individual (Plus/Pro) ChatGPT users.
- **Class D — remote MCP (Streamable HTTP)**: the chat-assistant class unlock (~5 surfaces: Claude.ai all-plans, ChatGPT, Perplexity paid, Le Chat all-plans, Grok — plus Devin). Splits into a LOW-cost bearer slice and a HIGH-cost OAuth 2.1 AS slice.

Honesty doctrine is a schema requirement: every matrix cell carries a vendor-doc citation + check-date; unverifiable reach is marked estimate/unknown; the tier sort key is **reach × installability**, never raw reach (Meta AI's 1B MAU with zero inbound path stays Tier 3).

## Decisions

1. **Doctrine spine = mechanism classes A–D**, not per-surface projects — one asset per class closes many surfaces; the paper and every slate task name surface(s) + mechanism + gate.
2. **The matrix lives INSIDE the Paper** — docs/cards is at its hard cap of 7 (check-doc-budgets.sh:69-76) so a card is impossible; a dated, perishable snapshot belongs in the living Paper; AGENT-ONRAMPS.md gets at most a pointer row (setup pages are not CI-byte-gated but stay lean).
3. **Matrix honesty is schema**: cell = value + citation + date-checked (2026-07-09 baseline); rows without citations don't ship; soft numbers (Windsurf/Cursor/Le Chat user bases) are marked estimate/unverified, never fabricated.
4. **Tier sort key = reach × installability** — who can actually install matters as much as MAU; Meta AI (1B) and consumer Gemini (900M) are structurally closed and sit in Tier 3 despite their size.
5. **Roo Code is DROPPED** — repo archived 2026-05-15, read-only (verified `gh api repos/RooCodeInc/Roo-Code`); Kilo Code (active fork) goes on the watch list. This corrects the strategize-phase direction.
6. **Onramp targets split into three emitter classes** (corrects the "one uniform cheap tier" premise): (i) verbatim `mcpJSONStanza` reuse — Windsurf, Gemini CLI, Cline; (ii) small-new-key emitters — Copilot (`servers` + `type:"stdio"`), Zed (`context_servers` + `source:"custom"`), Amp (nested `amp.mcpServers`); (iii) new-format emitters — Continue (YAML list), OpenHands (TOML `[mcp]`).
7. **The one permitted wave-1 code slice = `bp onramp windsurf` + `bp onramp gemini-cli`** — both reuse mcpJSONStanza verbatim (onramp_cmd.go:93), zero new mechanism, combined reach in the millions. Cline is deferred to wave 2 because its env block has no vendor-confirmed `${env:}` interpolation — an onramp must not risk writing the token into cline_mcp_settings.json. **Decide-phase corrections (2026-07-09):** (a) the verb is PRINT-ONLY (onramp_cmd.go:6-9; any `-flag` incl. `--write` rejects as unknown, TestOnrampRejectWriteFlag) — the user-global/settings-file write collision the strategize phase worried about is MOOT this wave; `--write` semantics stay the reserved wave-2/3 slice. (b) BOTH new targets print codex-style MERGE-into-existing guidance (onramp_cmd.go:278-282 pattern), never cursor's whole-file "→ path" label — Windsurf's `~/.codeium/mcp_config.json` is user-global and Gemini's `.gemini/settings.json` holds the whole CLI config; a whole-file label invites clobbering. (c) Dialects: windsurf reuses `cursorTokenRef` (`${env:BARKPARK_API_TOKEN}`) verbatim; gemini-cli gets its OWN named constant `geminiTokenRef` (braced `${BARKPARK_API_TOKEN}` form — builder confirms against github.com/google-gemini/gemini-cli docs/tools/mcp-server.md before hardcoding); dialects stay per-tool named constants (decision 9 legibility), never shared across tools even when values coincide.
8. **Remote MCP graduates and SPLITS, absorbing `ao-backlog-remote-mcp`**: (a) bearer-token Streamable HTTP endpoint = Tier 1, low cost (one wave slice, task `ve-w2-remote-mcp-bearer`); (b) full OAuth 2.1 authorization server (PKCE, /authorize + consent UI, /token, RFC 8707; DCR optional since Claude.ai/ChatGPT accept predefined clients) = Tier 2 (task `ve-w3-oauth-as`). The backlog task is patched with a supersession pointer, not duplicated. **EXECUTED 2026-07-09**: `ao-backlog-remote-mcp` → lifecycle `cancelled` + description supersession pointer, published (stays under agent-onramps-epic — no re-parent, avoids churning GitHub #1805's tree; the mirror closing #1805 is expected).
9. **Remote MCP builds GO-SIDE, not Phoenix** — the vendored go-sdk v1.6.1 (already backing `bp mcp serve`) ships `mcp.NewStreamableHTTPHandler` + `auth.RequireBearerToken` + RFC 9728 PRM handler; swapping the StdioTransport line (mcp_serve.go:101) for the HTTP handler reuses the identical tool registration. The bearer verifier calls Barkpark's existing `Auth.verify_token/1` choke point (auth.ex:27). REMOTE.md/agent-onramps-charter "Phoenix-side" wording is corrected in wave 1. CORS is a non-constraint: chat vendors call MCP server-to-server.
10. **Class B asset = ONE plain-markdown consumer AGENTS.md emission** (`bp onramp agents-md`) that collapses the three byte-parallel teach-layer wrappers (.cursor/rules/barkpark-tasks.mdc payload, .claude/CLAUDE-BARKPARK.md, CODEX.md AGENTS.md block). AGENTS.md is the ~23-tool convergence standard (agents.md, Linux Foundation); per-tool rules formats only add glob-scoping we don't need. Must reconcile bp-agent-onramps-charter decision 8 (filename-scan dodge) when built.
11. **Prompt-suggestion pack is CUT** — verified: no chat surface accepts an installable third-party prompt/slash pack (custom instructions/Gems/Projects are per-user config). No task filed; corrects the strategize-phase tentative.
12. **Skills package is Tier 2 with conservatively-cited reach** — SKILL.md folder distributable on Anthropic's four surfaces (claude.ai, Claude Code, Agent SDK, API); the "20-32 adopters" agentskills.io list is adopter marketing, not first-party-verified.
13. **REMOTE.md is refreshed in wave 1** (doc-only, not the code slice): ChatGPT Plus/Pro now get read-only remote MCP via Developer Mode (2026-03-13; write connectors stay Business/Ent/Edu — Actions remain the only WRITE path for Plus/Pro individuals); Claude.ai custom connectors are GA on ALL plans — the honest framing shifts from "Claude.ai can't" to "Claude.ai can, once we ship the remote endpoint". We cannot publish a paper that contradicts our own docs. **Scope (decide 2026-07-09):** the slice ALSO corrects bp-agent-onramps-charter.md:15+:45 ("Phoenix-side" → Go-side; "will not build a remote one" → superseded by `ve-w2-remote-mcp-bearer`). PRESERVE the still-true fact that stdio `bp mcp serve` cannot be registered as a Claude.ai connector. Forward refs to unshipped work are backtick code spans, never .md links (docs-anchors §3c). Neither REMOTE.md nor AGENT-ONRAMPS.md is CI-byte-gated (check-doc-budgets CAPS excludes them; budget header is advisory) — edit stays roughly size-neutral anyway; line-1 G1 header untouched.
14. **Paper publishes via `bp bulldocs publish viable-everywhere-strategy --file paper.json --yes`** — native blocks only (body_html-only papers fail `bp paper view`; `{"type":"table","rows":[…]}` is a native block with a TUI renderer, pdrender/richblocks.go:28), ingest-tier route accepts the admin bearer already configured for guerrilla. Epic link = `POST /v1/tasks/viable-everywhere-epic/papers` body `{"add":["viable-everywhere-strategy"]}` (tasks_controller.ex:19, task.referenced event) so `bp task get viable-everywhere-epic` lists it under papers. **TUI-legibility rule:** builder MUST verify `bp paper view viable-everywhere-strategy` at 80 cols; if the 7-column matrix wraps illegibly, restructure per-tier into compact tables (≤4 cols) with citation+check-date carried per-row — the honesty schema is non-negotiable in either shape.
15. **llms.txt is out of scope** (no provider committed, Google declined) — one watch-list line in the paper, no asset.
16. **The "byte-parity lock" is a manual three-artifact discipline, not automation** — verified: no script or test reads doc bytes; the lock is a hardcoded golden constant in onramp_cmd_test.go asserted via strings.Contains, with a prose citation comment naming the doc file+lines (pattern: test:24 ↔ CURSOR.md:78-91). The wave-1 builder writes the doc stanza, copies it VERBATIM into the test constant, asserts the verb prints it, and cites the doc lines — three artifacts kept identical by hand + reviewer. No cross-file automation is added this wave.
17. **The full slate is FILED as published children of `viable-everywhere-epic` at decide time (2026-07-09)** — wave-1 tasks carry full briefs; ve-w2-*/ve-w3-* are honest ledger placeholders (charter-referenced, re-briefed at their own decide phase), so the roadmap lives in the ledger, not just this file. GitHub mirroring of each child to its own issue + native sub-issue of #1872 is automatic and outbound-only — no builder action needed.

## Capability matrix — ground truth (checked 2026-07-09; paper expands this)

### Coding agents

| Surface | MCP | Config (key · path · env dialect) | Rules file | Users | Tier | Citation |
|---|---|---|---|---|---|---|
| GitHub Copilot (agent mode) | stdio + http | `servers` + `type:"stdio"` · `.vscode/mcp.json` · `${env:VAR}` + inputs; cloud agent `COPILOT_MCP_*` secrets | `.github/copilot-instructions.md`; AGENTS.md | ~20M total / 4.7M paid | T1 (new small emitter) | code.visualstudio.com/docs/agent-customization/mcp-servers |
| Windsurf (Cascade) | stdio + StreamHTTP + SSE + OAuth | `mcpServers` · `~/.codeium/mcp_config.json` · `${env:VAR}` | `.windsurf/rules/`, AGENTS.md | millions (estimate) | T1 wave-1 (verbatim stanza) | docs.devin.ai/windsurf/plugins/cascade/mcp (windsurf.com 307s there; Cognition owns both) |
| Gemini CLI | stdio + remote | `mcpServers` · `~/.gemini/settings.json` or `.gemini/settings.json` · auto env expansion | GEMINI.md; AGENTS.md | growing, OSS | T1 wave-1 (verbatim stanza) | github.com/google-gemini/gemini-cli docs/tools/mcp-server.md |
| Cline | stdio + remote | `mcpServers` · `cline_mcp_settings.json` (globalStorage) · env literal — **no confirmed `${env:}`** | `.clinerules/` ; AGENTS.md partial | 5M+ installs | T1 wave-2 (verify token handling) | docs.cline.bot/mcp/adding-and-configuring-servers |
| Zed | stdio ("context servers") | `context_servers` + `source:"custom"` · `settings.json` / `.zed/settings.json` | `.rules`, AGENTS.md | active OSS | T1 wave-2 (new key) | zed.dev/docs/ai/mcp |
| Continue | stdio | `mcpServers` YAML LIST · `.continue/config.yaml` | `.continue/rules/`, `uses:` packages | ~26-31k stars | T2 (YAML emitter) | docs.continue.dev/customize/deep-dives/mcp |
| Amp | stdio + remote | `amp.mcpServers` nested · VS Code settings.json / `~/.config/amp/settings.json` | AGENT.md (SINGULAR) | paid, active | T2 | ampcode.com/manual |
| OpenHands | stdio | `[mcp]` TOML · `config.toml` | `.openhands/microagents/repo.md`, AGENTS.md | active OSS | T2 (TOML emitter) | docs.openhands.dev mcp-settings |
| Aider | **NO native MCP** (PRs closed) | — | CONVENTIONS.md / `--conventions-file`; reads AGENTS.md | ~4.1M installs / 40k stars | T2 via Class B only | github.com/aider-ai/aider #4363 |
| Devin | hosted MCP marketplace only (UI, no committable file) | — | Knowledge + AGENTS.md | closed/hosted | T2 beneficiary of Class D; T3 for onramp | docs.devin.ai/work-with-devin/mcp |
| Roo Code | ARCHIVED 2026-05-15 | — | — | 24.3k stars frozen | DROP | gh api repos/RooCodeInc/Roo-Code archived:true |
| Kilo Code (Roo/Cline fork) | (unverified) | — | — | — | T3 watch | successor watch item |
| Copilot Workspace | folding into Copilot coding agent (not deep-verified) | — | — | — | T3 watch | flag: confirm before paper asserts |

### Chat assistants

| Surface | Remote MCP connector | Who can install | OpenAPI actions | Users | Tier | Citation |
|---|---|---|---|---|---|---|
| ChatGPT | YES — Developer Mode remote MCP (2026-03-13); write connectors Business/Ent/Edu, Plus/Pro read-only | Plus/Pro (read), Business+ (write) | **YES — Custom GPT Actions, works TODAY** (public /v1/openapi.json) | 900M WAU / >1.1B monthly | C today; D adds write for Business+ | help.openai.com "Developer mode and MCP apps" |
| Claude.ai | YES — custom connectors, OAuth 2.1/PKCE; bearer/header auth is BETA (contact Anthropic) | ALL plans incl. Free (Free=1) | no | 245M monthly | D unlock (+ Skills T2) | support.claude.com "custom connectors using remote MCP" |
| Perplexity | YES — None/API-Key/OAuth 2.0 (2026-03-13) | Pro/Max/Enterprise | no | ~100M MAU | D unlock | perplexity.ai help "Adding Custom Remote Connectors" |
| Mistral Le Chat | YES — any remote MCP server | ALL incl. Free | no | unverified (est. tens of M) | D unlock | mistral.ai/news "Custom MCP connectors" |
| Grok (xAI) | YES — Connectors + BYO-MCP (2026-05-06); plan gates unverified | consumer (verify gates) | no | <5% share | D unlock, mid reach | x.ai/news "Grok Connectors"; docs.x.ai remote-mcp |
| Google Gemini (consumer) | NO custom MCP (Enterprise/CLI only) | — | no | 900M MAU | T3 closed (CLI is Class A) | support.google.com Gemini threads |
| Meta AI | NO third-party inbound (Meta Ads MCP is outbound, for OTHER clients) | — | no | 1B MAU | T3 closed | commonthreadco/gomarble 2026-04-29 |
| Microsoft Copilot (consumer) | NO (Copilot Studio = enterprise/admin) | — | enterprise only | — | T3 closed | learn.microsoft.com Copilot Studio MCP |
| Pi (Inflection) | NO mechanism at all | — | no | small/declining | T3 drop | aitoolsdevpro Pi guide |

Perishability: every mechanism above shipped Mar–Jun 2026 and vendors move monthly — the paper stamps check-dates per cell and is a dated snapshot, re-verified per wave.

## Tiering

- **Tier 1 (build now — mechanism exists)**: onramp windsurf + gemini-cli (wave 1); remote-MCP bearer endpoint; canonical AGENTS.md emission; onramp copilot; onramp zed + cline.
- **Tier 2 (one new asset)**: OAuth 2.1 AS (Claude.ai/ChatGPT GA self-serve unlock); Barkpark SKILL.md package; long-tail emitters (Continue YAML, OpenHands TOML, Amp).
- **Tier 3 (watch — closed/immature)**: Meta AI, Pi, consumer Gemini chat, consumer MS Copilot, Devin-onramp, Copilot Workspace, Kilo Code, llms.txt. No tasks filed; paper records why, honestly.

## Roadmap

**Wave 1 (this wave — plan artifacts + the one cheap code slice):**
1. `ve-w1-strategy-paper` (large, P0) — matrix + doctrine Paper, native blocks, published to guerrilla, linked to epic.
2. `ve-w1-onramp-windsurf-gemini` (medium, P1) — `bp onramp windsurf|gemini-cli`, golden tests, per-target docs, byte-parity lock.
3. `ve-w1-remote-md-refresh` (small, P1) — REMOTE.md honesty refresh (ChatGPT/Claude.ai staleness + Go-side correction).

**Wave 2 (Tier 1 build):**
4. `ve-w2-remote-mcp-bearer` (large, P1) — Go Streamable-HTTP MCP endpoint, bearer auth via verify_token; ABSORBS ao-backlog-remote-mcp. Spike-verify go-sdk handler wiring first (uncompiled-prototype risk).
5. `ve-w2-agents-md-onramp` (medium, P1) — canonical consumer AGENTS.md emission; collapse 3 teach-layer wrappers; reconcile onramps-charter decision 8.
6. `ve-w2-onramp-copilot` (small, P1) — `.vscode/mcp.json` `servers` emitter (highest single-surface reach).
7. `ve-w2-onramp-zed-cline` (medium, P2) — Zed `context_servers` emitter + Cline (after env-token verification).

**Wave 3 (Tier 2):**
8. `ve-w3-oauth-as` (large, P2) — OAuth 2.1 authorization server on the login-ticket/device-link consent substrate; Claude.ai GA + ChatGPT self-serve unlock.
9. `ve-w3-skills-package` (medium, P2) — Barkpark SKILL.md package for Anthropic surfaces.
10. `ve-w3-onramp-longtail` (medium, P3) — Continue YAML + OpenHands TOML + Amp nested-key emitters.

## Wave log

**Wave 1 · Decide (2026-07-09):** Decisions 7/8/13/14 amended with explorer ground truth (print-only verb → collision moot; merge-note guidance; geminiTokenRef; supersession executed; refresh scope includes onramps charter; verified publish+link verbs; TUI-legibility rule); decisions 16-17 added (byte-parity = manual discipline; slate filed). All 10 slate tasks filed published under `viable-everywhere-epic` (w1: `ve-w1-strategy-paper` P0 / `ve-w1-onramp-windsurf-gemini` P1 / `ve-w1-remote-md-refresh` P1; w2: bearer P1, agents-md P1, copilot P1, zed-cline P2; w3: oauth-as P2, skills P2, longtail P3). `ao-backlog-remote-mcp` cancelled with supersession pointer. Wave 1 builds EXACTLY the three w1 slices — nothing from wave 2.

### Wave 2026-07-09 (wave 1 · build + review)

**Landed — all three slices green, nothing stalled.**

1. **`ve-w1-strategy-paper`** (content-only, no branch): `viable-everywhere-strategy` live on guerrilla — 43 native blocks, mechanism classes A–D, all 22 surface rows restructured per-tier ≤4-col (D14, zero overwide lines at 80 cols), honesty schema enforced (citations + 2026-07-09 stamps + (est.)/unverified markers + Tier-3 why-closed), full-URL Citations table, epic link live. Reviewer verified reader HTTP 200, TUI at default+80 cols, and both wave-1 dialects against LIVE vendor docs (gemini-cli `${VAR}` confirmed; windsurf `${env:VAR}` confirmed). **Reviewer fix:** paper carried only decisions 1–15 — decisions 16–17 (byte-parity manual lock; slate filed) appended via `bp bulldocs patch` (now rev 2). Lead still owes criterion 5 (Studio visual pass at the Kinsta bar).
2. **`ve-w1-onramp-windsurf-gemini`** → integrate `loop-epic/bp-onramp-windsurf-gemini-cli-at-parity--1-r`: both emitters at parity, verbatim mcpJSONStanza, print-only intact, golden tests byte-match the docs (citations WINDSURF.md:50-61 / GEMINI-CLI.md:51-62 verified line-exact), dialect-leak guards, WINDSURF.md + GEMINI-CLI.md + 2 hub rows. **Reviewer fix (the -r commit):** AGENT-ONRAMPS.md "code spans until their PRs land" caveat was stale (CODEX/CLAUDE-CODE landed long ago; this PR lands the rest) — all seven target rows are now live links. Full gate green on -r.
3. **`ve-w1-remote-md-refresh`** → integrate `loop-epic/remote-md-tells-the-truth-again-chatgpt--2` unchanged: REMOTE.md + onramps-charter honesty refresh exactly per D13 — Plus/Pro read-only Developer-Mode MCP, Claude.ai GA-all-plans / gap-is-ours framing, Go-side correction (mcp_serve.go:101 verified accurate), supersession pointers. Gate green; no reviewer changes.

**Ledger:** truthful across the slate — 3 w1 tasks in_progress with active epoch-1 claims and evidence-stamped criteria (merge-gated criterion open for the lead); w2/w3 placeholders untouched open; ao-backlog-remote-mcp cancelled+pointed. No fixes needed. NOTE for lead: builders stamped criteria via doc-patch under the claim, so `bp task close` will 409 `doc_changed_since_claim` — re-read then close (documented recovery).

**Next wave (w2 cut):** `ve-w2-remote-mcp-bearer` is the unlock (spike-verify go-sdk NewStreamableHTTPHandler wiring FIRST — uncompiled-prototype risk) + `ve-w2-agents-md-onramp` (must reconcile onramps-charter decision 8) + `ve-w2-onramp-copilot` (highest single-surface reach, small). Re-verify the paper's perishable matrix cells at w2 decide (Grok plan gates, Kilo dialect, Cline `${env:}` are the open unknowns). Consider promoting the paper-payload generator out of scratchpad if per-wave re-verification wants regeneration.
