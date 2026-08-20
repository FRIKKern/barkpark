# .claude/workflows

The `*.workflow.js` files here are orchestration engines for the Claude Code
Workflow harness — each drives a full multi-agent cycle (epic waves, bulk
sweeps, investigations) with the bp task ledger as its spine. The
`*-charter.md` files are the epics' memory; charters and engines version
together in this directory.

Discovery is a **flat** readdir of this directory: any `*.js` file registers,
subdirectories are invisible, `.mjs`/`.cjs`/`.ts` are skipped, files over
512 KiB are skipped, and `export const meta` must be the FIRST statement and a
pure object literal (`name` + `description` required).

Prerequisites, the full launch invocation, and the resume rules live in
[docs/setup/CLAUDE-CODE.md](../../docs/setup/CLAUDE-CODE.md), section "Run an
epic wave from any machine". Launch by `scriptPath`, never by name.
