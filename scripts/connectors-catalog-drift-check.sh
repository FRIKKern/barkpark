#!/usr/bin/env bash
# connectors-catalog-drift-check.sh — DB-free drift gate for the bridge-owned
# CONNECT registry vs the Elixir catalog's hand-mirror of it (connectors D75).
#
# The connect wire (D50/D51) is exactly three routes — /connect/validate,
# /connect, /disconnect. There is deliberately NO catalog endpoint (see
# api/lib/barkpark/connectors/catalog.ex moduledoc §"Why connectable? is
# declared HERE and not asked of the bridge"), so Studio CANNOT ask the bridge
# which providers declare a connect member. Barkpark.Connectors.Catalog
# therefore DECLARES each provider's `connect_mode` statically — a SECOND source
# of truth that MIRRORS the bridge registry by hand. This gate reds when the two
# disagree on the connectable-provider SET (and its mode), so a provider can
# never show a paste/oauth button the bridge can't honor, nor hide one it can.
#
# The static list in catalog.ex REMAINS the fail-closed fallback at runtime
# (a dead bridge degrades to a read-only card, never a broken page). This is a
# CI drift tripwire, NOT a live bridge read — it does not reverse catalog.ex's
# no-endpoint design law, and it adds no providers[] to /health.
#
# Modeled EXACTLY on scripts/connectors-ddl-drift-check.sh: pure bash 3.2 + awk,
# NO database, a bundled --selftest so a broken extractor can never read green.
#
# The two sources of the connectable set:
#   · CATALOG (Elixir): api/lib/barkpark/connectors/catalog.ex — each @providers
#     entry pairs `id: "<p>"` with `connect_mode: :paste | :oauth | nil`. A nil
#     mode is NON-connectable (teams/whatsapp/imessage) and emits nothing.
#   · BRIDGE (TypeScript):
#       - paste providers declare a `connect: {` member in
#         connectors/src/connectors/<p>.ts   → "<p> paste"
#       - oauth providers have an <p>-oauth.ts callback in
#         connectors/src/oauth/                → "<p> oauth"
#     A TOOL connector (`direction: "tool"` — GitHub, connectors D69) also has a
#     `connect: {` member but is NOT a channel and is EXCLUDED — catalog.ex is
#     the CHANNEL catalog and omits it, so counting it would false-drift.
#
# `--selftest` proves the tripwire in temp files (plants nothing in the tree):
# an agreeing catalog+bridge stays green; a bridge that drops one provider's
# connect member (catalog still claims it) reds; a tool-direction connector is
# excluded from the channel set.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CATALOG_EX="api/lib/barkpark/connectors/catalog.ex"
CONNECTORS_DIR="connectors/src/connectors"
OAUTH_DIR="connectors/src/oauth"

# Extract the sorted "<provider> <mode>" set from the Elixir catalog. Scans ONLY
# the `@providers [ … ]` list body (so the @type/@typedoc doc lines that also
# say `id:`/`connect_mode:` are skipped): inside the block each `id: "<p>"`
# names the current provider and a following `connect_mode: :paste|:oauth`
# emits "<p> <mode>". `connect_mode: nil` matches nothing → non-connectable
# providers emit no line. Char classes explicit for BSD-awk (macOS) / gawk (CI)
# parity; whitespace matched as [ \t].
extract_catalog() {
  awk '
    /@providers[ \t]*\[/ { inblock=1; next }
    inblock && /^[ \t]*\][ \t]*$/ { inblock=0; next }
    inblock {
      if (match($0, /id:[ \t]*"[a-z0-9_]+"/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/^id:[ \t]*"|"$/, "", s)
        curid = s
      }
      if (match($0, /connect_mode:[ \t]*:[a-z]+/)) {
        m = substr($0, RSTART, RLENGTH)
        sub(/^connect_mode:[ \t]*:/, "", m)
        if ((m == "paste" || m == "oauth") && curid != "") print curid " " m
      }
    }
  ' "$1" | sort -u
}

# Extract the sorted "<provider> <mode>" set the BRIDGE actually implements:
#   paste = a connectors/<p>.ts declaring a `connect: {` member;
#   oauth = a <p>-oauth.ts callback under the oauth dir.
# $1 = connectors dir, $2 = oauth dir (parameterized so --selftest can point
# both at temp trees).
extract_bridge() {
  local cdir="$1" odir="$2" f base prov
  {
    if [ -d "$cdir" ]; then
      for f in "$cdir"/*.ts; do
        [ -f "$f" ] || continue
        # A paste connector declares an object member `connect: {` (the mode
        # lives inside it). A helper file (e.g. gateway.ts) has no such member
        # and is excluded by construction — presence of the member IS the
        # definition of paste-connectable.
        #
        # BUT a TOOL connector (`direction: "tool"` — GitHub, connectors D69, the
        # epic's OTHER direction) ALSO declares a `connect: {` paste member (its
        # PAT is pasted the same way), yet it is NOT a channel and never appears
        # in the Studio CHANNEL catalog (catalog.ex declares only channels). So a
        # file that declares `direction: "tool"` is EXCLUDED here — the channel
        # catalog mirrors CHANNEL connectors only. A `direction: "both"` connector
        # is still a channel and stays. (When a tool CATALOG lands, this gate gets
        # a tool-set companion; today catalog.ex has no tool section to mirror.)
        if grep -Eq '^[[:space:]]*connect:[[:space:]]*\{' "$f" &&
           ! grep -Eq '^[[:space:]]*direction:[[:space:]]*"tool"' "$f"; then
          base="$(basename "$f" .ts)"
          echo "$base paste"
        fi
      done
    fi
    if [ -d "$odir" ]; then
      for f in "$odir"/*-oauth.ts; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .ts)"
        prov="${base%-oauth}"
        echo "$prov oauth"
      done
    fi
  } | sort -u
}

flat() { printf '%s\n' "$1" | tr '\n' ' ' | sed 's/ *$//'; }

selftest() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # A faithful mini-catalog: two paste, one oauth, and one nil (non-connectable,
  # must emit nothing). The @type doc lines above the list deliberately repeat
  # `id:`/`connect_mode:` to prove the block-scoping skips them.
  cat > "$tmp/catalog.ex" <<'EOF'
  @type provider :: %{
          id: String.t(),
          connect_mode: connect_mode()
        }

  @providers [
    %{
      id: "telegram",
      connectable?: true,
      connect_mode: :paste,
      gate: nil
    },
    %{
      id: "discord",
      connectable?: true,
      connect_mode: :paste,
      gate: nil
    },
    %{
      id: "slack",
      connectable?: false,
      connect_mode: :oauth,
      gate: nil
    },
    %{
      id: "teams",
      connectable?: false,
      connect_mode: nil,
      gate: "azure admin consent"
    }
  ]
EOF

  mkdir -p "$tmp/agree/connectors" "$tmp/agree/oauth" \
           "$tmp/drift/connectors" "$tmp/drift/oauth"

  # agree bridge: telegram + discord paste connectors, a helper with NO member,
  # and the slack oauth callback.
  for p in telegram discord; do
    cat > "$tmp/agree/connectors/$p.ts" <<EOF
export const ${p}Connector = {
    connect: {
      mode: "paste",
    },
};
EOF
  done
  cat > "$tmp/agree/connectors/gateway.ts" <<'EOF'
// shared helper — NO connect member, must be excluded
export function mount() {}
EOF
  # A TOOL connector (connectors D69): it HAS a `connect: {` paste member (a PAT
  # is pasted), but `direction: "tool"` means it is NOT a channel and must be
  # EXCLUDED from the channel-catalog connectable set — the catalog omits it, so
  # a naive extractor would false-drift on it. This proves the tool exclusion.
  cat > "$tmp/agree/connectors/github.ts" <<'EOF'
export const githubConnector = {
    direction: "tool",
    connect: {
      mode: "paste",
    },
};
EOF
  cat > "$tmp/agree/oauth/slack-oauth.ts" <<'EOF'
export function slackCallback() {}
EOF

  # drift bridge: identical EXCEPT discord's connect member is gone — the bridge
  # can no longer paste-connect discord, but the catalog still claims it.
  cp "$tmp/agree/connectors/telegram.ts" "$tmp/drift/connectors/telegram.ts"
  cp "$tmp/agree/connectors/gateway.ts"  "$tmp/drift/connectors/gateway.ts"
  cp "$tmp/agree/oauth/slack-oauth.ts"   "$tmp/drift/oauth/slack-oauth.ts"
  cat > "$tmp/drift/connectors/discord.ts" <<'EOF'
// connect member REMOVED — discord no longer paste-connectable on the bridge
export const discordConnector = {};
EOF

  local cat_set agree_set drift_set
  cat_set="$(extract_catalog "$tmp/catalog.ex")"
  agree_set="$(extract_bridge "$tmp/agree/connectors" "$tmp/agree/oauth")"
  drift_set="$(extract_bridge "$tmp/drift/connectors" "$tmp/drift/oauth")"

  if [ -z "$cat_set" ] || [ -z "$agree_set" ]; then
    echo "SELFTEST FAIL: extraction produced an empty connectable set"; return 1
  fi
  # The nil provider (teams) must NOT appear on the catalog side.
  if printf '%s\n' "$cat_set" | grep -q '^teams '; then
    echo "SELFTEST FAIL: a nil connect_mode leaked into the connectable set"; return 1
  fi
  # The TOOL connector (github, direction:"tool") must NOT appear on the bridge
  # side — it has a connect member but is not a channel (connectors D69).
  if printf '%s\n' "$agree_set" | grep -q '^github '; then
    echo "SELFTEST FAIL: a tool-direction connector leaked into the channel connectable set"; return 1
  fi
  if [ "$cat_set" != "$agree_set" ]; then
    echo "SELFTEST FAIL: an agreeing catalog+bridge was reported as drift"
    echo "  catalog: [$(flat "$cat_set")]"
    echo "  bridge:  [$(flat "$agree_set")]"
    return 1
  fi
  if [ "$cat_set" = "$drift_set" ]; then
    echo "SELFTEST FAIL: a dropped connect member went undetected"; return 1
  fi
  echo "selftest OK: agree→green, dropped connect member→red, nil mode excluded, tool direction excluded"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

cd "$REPO_ROOT"

[ -f "$CATALOG_EX" ] || { echo "FAIL: catalog source not found: $CATALOG_EX"; exit 1; }
[ -d "$CONNECTORS_DIR" ] || { echo "FAIL: bridge connectors dir not found: $CONNECTORS_DIR"; exit 1; }

CATALOG_SET="$(extract_catalog "$CATALOG_EX")"
BRIDGE_SET="$(extract_bridge "$CONNECTORS_DIR" "$OAUTH_DIR")"

# An empty set means the extractor found nothing (anchors moved / block
# renamed), NOT that the two sources agree — fail closed, never vacuous-green.
if [ -z "$CATALOG_SET" ]; then
  echo "FAIL: no connectable providers parsed from $CATALOG_EX (@providers block moved or renamed?)"; exit 1
fi
if [ -z "$BRIDGE_SET" ]; then
  echo "FAIL: no connectable providers parsed from $CONNECTORS_DIR / $OAUTH_DIR (connect member or *-oauth.ts moved or renamed?)"; exit 1
fi

if [ "$CATALOG_SET" != "$BRIDGE_SET" ]; then
  only_catalog="$(comm -23 <(printf '%s\n' "$CATALOG_SET") <(printf '%s\n' "$BRIDGE_SET") | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  only_bridge="$(comm -13 <(printf '%s\n' "$CATALOG_SET") <(printf '%s\n' "$BRIDGE_SET") | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  echo "FAIL: connectable-provider DRIFT — the Elixir catalog and the bridge registry disagree (connectors D75)"
  echo "  $CATALOG_EX declares [$(flat "$CATALOG_SET")]"
  echo "  but the bridge implements [$(flat "$BRIDGE_SET")]"
  [ -n "$only_catalog" ] && echo "  catalog claims, bridge lacks:  $only_catalog"
  [ -n "$only_bridge" ]  && echo "  bridge implements, catalog omits: $only_bridge"
  echo "  → reconcile catalog.ex connect_mode with the bridge's connect: member / *-oauth.ts callback (two sources of one truth; catalog.ex stays the fail-closed fallback)"
  exit 1
fi

echo "connectors-catalog-drift-check: PASS — connectable providers agree [$(flat "$CATALOG_SET")]"
