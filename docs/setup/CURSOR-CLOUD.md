<!-- doc-tier: human | canonical-for: cursor-cloud-onramp | budget: 800tok -->
# Barkpark in Cursor Cloud

Cursor's cloud agents run in a fresh remote VM, not your laptop, so the onramp is two moves: **install `bp` when the box boots**, and **feed the token through Cursor's Secrets UI** — never a committed file. The shared AUTH and CREATE journeys live in [Agent Onramps](AGENT-ONRAMPS.md); this is only what Cursor Cloud does differently.

> Cursor's cloud-agent config keys move faster than this doc. Confirm the current names at [cursor.com/docs/cloud-agent/setup](https://cursor.com/docs/cloud-agent/setup) before you commit.

**Register the movement** — every unit of work runs under a claimed `bp` task: claim before you work, stamp evidence as you prove it, close on the claim epoch. The full doctrine, and the three ways a registration silently does not happen, is in [Agent Onramps](AGENT-ONRAMPS.md).

## 1. Install `bp` at boot

Cursor Cloud reads `.cursor/environment.json` from your repo root. Its `install` command runs on every fresh VM — put the CLI installer there:

```json
{
  "install": "curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh"
}
```

The installer drops `bp` in `/usr/local/bin`, or `~/.local/bin` when that isn't writable (common on cloud VMs); if the agent can't find it, add the fallback directory to the VM's `PATH` (or set `install` to install into a directory already on `PATH`).

## 2. Token via Secrets, never the repo

`.cursor/environment.json` is **committed** — a token in it leaks to everyone with repo access. Instead, set the two connection variables in Cursor's **Secrets** tab (Settings → cursor.com), which Cursor exposes to the cloud agent as environment variables:

- `BARKPARK_API_URL` — your instance, e.g. `https://guerrilla.barkpark.cloud`
- `BARKPARK_API_TOKEN` — a scoped bearer (`bp_admin_...`)

`bp`'s environment layer sits above the config file, so these two alone point every command — and the MCP server below — at your Barkpark. No `bp setup` needed on the VM.

## 3. MCP tools (optional)

Cursor Cloud reads the same `.cursor/mcp.json` as the desktop. Drop in the stanza from [CURSOR.md](CURSOR.md) **verbatim** — the `${env:VAR}` dialect is Cursor's, and it resolves `BARKPARK_API_TOKEN` from the Secrets-provided environment, so the token still never lands in a committed file:

```json
{
  "mcpServers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${env:BARKPARK_API_TOKEN}"
      }
    }
  }
}
```

Point it at a Barkpark with the **Tasks plugin enabled** — `bp mcp serve` fails fast otherwise.

## Verify

In the cloud agent's terminal:

```bash
bp task ready     # empty list = connected, no open work
```

A clean list means the box installed `bp`, read the Secrets, and reached your instance. From there the agent has the full API — `bp capabilities -o json`.
