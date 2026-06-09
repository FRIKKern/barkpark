<!-- doc-tier: agent | canonical-for: shell-danger-rules | budget: 150tok -->
# Agent Instructions

Canonical guide: **CLAUDE.md** (this directory). Read it first.

Danger rules — always apply:

- Non-interactive shell flags only: `cp -f`, `mv -f`, `apt-get -y`, `ssh`/`scp -o BatchMode=yes` — never hang on a y/n prompt.
- Never `rm` — use `trash` (recoverable). Sole exception: the scripted `rm -rf api/_build/prod` inside `make rebuild` on the server.
- Never raw `mix compile` on the server — use `make rebuild` or `make deploy`.
- Never partially clean `_build` — nuke the entire `_build/prod`.
- Always `systemctl restart` after compiling — the old BEAM stays in memory.
