<!-- doc-tier: cold | canonical-for: pe-w7-hermetic-harness-dryrun-rederivation | budget: 800tok -->
# Paper Excellence W7 — hermetic cold-spawn harness dry-run (re-derivation recipes)

Host: darwin 24.5.0. Real claude binary `/Users/pelle/.local/bin/claude` (v2.1.233) — the
PATH `claude` is a cmux shim (`/Volumes/SATECHI/dev-caches/tmp//cmux-cli-shims/.../claude`)
that execs `cmux-claude-wrapper` (injects OAuth). Call the REAL binary by absolute path to
bypass the shim. `env -i` already drops the shim from PATH.

SCRATCH=/Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/ba5f66f9-9370-4639-ae79-5f38bb0e7fe1/scratchpad
CLAUDE=/Users/pelle/.local/bin/claude
BASEPATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Users/pelle/.local/bin

## Fact: --bare spawns cleanly hermetically; transcript is parseable JSONL
env -i PATH="$BASEPATH" HOME="$SCRATCH/home" "$CLAUDE" --bare -p 'print COLD-OK' \
  --output-format stream-json --verbose > $SCRATCH/probe.jsonl 2>&1
# → 3 lines: {type:system,subtype:init,...} / assistant / {type:result}. json.loads each line OK.

## Fact: --bare REQUIRES ANTHROPIC_API_KEY — keychain OAuth never used (even with real HOME)
# no key  → apiKeySource="none", assistant text "Not logged in · Please run /login"
# real HOME + no key (PROBE 4) → SAME failure (bare skips keychain reads, per --help)
env -i PATH="$BASEPATH" HOME=/Users/pelle "$CLAUDE" --bare -p x --output-format stream-json --verbose
# with key → apiKeySource flips to "ANTHROPIC_API_KEY" (auth attempted via the key):
env -i PATH="$BASEPATH" HOME="$SCRATCH/home" ANTHROPIC_API_KEY="sk-ant-..." "$CLAUDE" --bare ...
# NOTE: only an OAuth oat01 token exists in keychain ("Claude Code-credentials"); NOT an
# sk-ant-api key. No usable ANTHROPIC_API_KEY is present on this host. Harness must provision one.

## Fact: --setting-sources '' is accepted (no flag-parse error on stderr)
env -i PATH="$BASEPATH" HOME="$SCRATCH/home" ANTHROPIC_API_KEY=k "$CLAUDE" --bare --setting-sources '' -p x ...

## Fact: bp runs fully non-interactive under scratch XDG_CONFIG_HOME + env -i
mkdir -p $SCRATCH/cfg/barkpark
# config.json needs only server+token+workspace+project+dataset:
# {"server":"https://guerrilla.barkpark.cloud","token":"bp_admin_...","workspace":"default","project":"default","dataset":"production"}
env -i PATH="$BASEPATH" HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/cfg" bp whoami -o json
# → {"auth_tier":"admin","reachable":true,"token_present":true,...} exit 0, no setup prompt
env -i PATH="$BASEPATH" HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/cfg" bp paper view paper-authoring-excellence | head
# → renders title "PAPER AUTHORING EXCELLENCE" + BPML-door body ("bp paper new" / "bp paper push")
