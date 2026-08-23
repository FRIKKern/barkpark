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

# Env-overridable scan paths (the seam --selftest re-invokes "$0" through, as
# studio-link-lint's STUDIO_LINK_LINT_ROOT does): absolute paths welcome.
CATALOG_EX="${CONNECTORS_CATALOG_EX:-api/lib/barkpark/connectors/catalog.ex}"
CONNECTORS_DIR="${CONNECTORS_CATALOG_CONNECTORS_DIR:-connectors/src/connectors}"
OAUTH_DIR="${CONNECTORS_CATALOG_OAUTH_DIR:-connectors/src/oauth}"

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
        # A TOOL connector (`direction: "tool"` — Linear, connectors D77, the epic's
        # OTHER direction) ALSO connects over OAuth (a <p>-oauth.ts callback), yet it
        # is NOT a channel: its registry file `connectors/<p>.ts` declares
        # `direction: "tool"`, and catalog.ex (the CHANNEL catalog) omits it. So a
        # <p>-oauth.ts whose sibling registry file is a tool is EXCLUDED here, exactly
        # as the paste loop above excludes a tool `connect:` member (github). Without
        # this a linear-oauth.ts would false-drift against a catalog that correctly
        # omits it. The exclusion fires ONLY when the registry file exists AND declares
        # the tool direction, so a channel oauth (slack) is never touched.
        if [ -f "$cdir/$prov.ts" ] &&
           grep -Eq '^[[:space:]]*direction:[[:space:]]*"tool"' "$cdir/$prov.ts"; then
          continue
        fi
        echo "$prov oauth"
      done
    fi
  } | sort -u
}

# ── TOOL SET (variant B — the OUTBOUND direction, D99/D100) ──────────────────
#
# The catalog now carries a SEPARATE `@tool_providers [ … ]` block for the tool
# connectors (github/linear — the OTHER direction). These two extractors are the
# MIRROR IMAGE of the channel ones: the tool catalog block, and the bridge's
# tool-direction connectors (exactly the ones the CHANNEL extractor EXCLUDES).
# They are PURELY ADDITIVE — the channel extractors above are byte-unchanged.

# Extract the sorted "<provider> <mode>" set from the catalog's `@tool_providers`
# block. Identical shape to extract_catalog, scanning the tool block instead — a
# `@tool_providers [` opens it, a lone `]` closes it. `@providers` never matches
# `@tool_providers` (and vice-versa) because the literal `@providers` is not a
# substring of `@tool_providers` — the two blocks are extracted independently.
extract_catalog_tools() {
  awk '
    /@tool_providers[ \t]*\[/ { inblock=1; next }
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

# Extract the sorted "<provider> <mode>" set the BRIDGE implements as TOOL
# connectors — the exact complement of extract_bridge's exclusions:
#   paste = a connectors/<p>.ts declaring BOTH a `connect: {` member AND
#           `direction: "tool"` (github);
#   oauth = a <p>-oauth.ts callback whose sibling connectors/<p>.ts declares
#           `direction: "tool"` (linear).
# $1 = connectors dir, $2 = oauth dir (parameterized for --selftest temp trees).
extract_bridge_tools() {
  local cdir="$1" odir="$2" f base prov
  {
    if [ -d "$cdir" ]; then
      for f in "$cdir"/*.ts; do
        [ -f "$f" ] || continue
        # A TOOL paste connector: a `connect: {` member AND `direction: "tool"`
        # (github pastes a PAT). This is precisely the case the channel paste loop
        # EXCLUDES, collected here instead.
        if grep -Eq '^[[:space:]]*connect:[[:space:]]*\{' "$f" &&
           grep -Eq '^[[:space:]]*direction:[[:space:]]*"tool"' "$f"; then
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
        # A TOOL oauth connector: a <p>-oauth.ts whose registry file declares
        # `direction: "tool"` (linear). This is precisely the case the channel
        # oauth loop EXCLUDES, collected here instead. A channel oauth (slack,
        # whose registry is not a tool) is skipped.
        if [ -f "$cdir/$prov.ts" ] &&
           grep -Eq '^[[:space:]]*direction:[[:space:]]*"tool"' "$cdir/$prov.ts"; then
          echo "$prov oauth"
        fi
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

  # A SEPARATE tool block, EXACTLY as the real catalog carries it. Its presence
  # must NOT perturb the channel extractor above (proven below: cat_set must not
  # contain github/linear), and it is the catalog side of the tool-set check.
  @tool_providers [
    %{
      id: "github",
      connectable?: true,
      connect_mode: :paste,
      direction: :tool,
      gate: nil
    },
    %{
      id: "linear",
      connectable?: false,
      connect_mode: :oauth,
      direction: :tool,
      gate: nil
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
  # A TOOL connector that connects over OAUTH (connectors D77 — Linear). Its registry
  # file declares `direction: "tool"` and has NO `connect:` member (it is OAuth-only),
  # and it has a <p>-oauth.ts callback. It is NOT a channel, so the channel catalog
  # omits it — a naive OAUTH-loop extractor would emit "linear oauth" and false-drift.
  # This pair proves the OAUTH-loop tool exclusion, which the paste case (github)
  # above does NOT exercise (the bundled selftest was BLIND to this branch before D82).
  cat > "$tmp/agree/connectors/linear.ts" <<'EOF'
export const linearConnector = {
    direction: "tool",
};
EOF
  cat > "$tmp/agree/oauth/linear-oauth.ts" <<'EOF'
export function linearCallback() {}
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
  if grep -q '^teams ' <<<"$cat_set"; then
    echo "SELFTEST FAIL: a nil connect_mode leaked into the connectable set"; return 1
  fi
  # The TOOL connector (github, direction:"tool") must NOT appear on the bridge
  # side — it has a connect member but is not a channel (connectors D69).
  if grep -q '^github ' <<<"$agree_set"; then
    echo "SELFTEST FAIL: a tool-direction connector leaked into the channel connectable set"; return 1
  fi
  # The OAUTH tool connector (linear, direction:"tool" + linear-oauth.ts) must NOT
  # appear either — the OAUTH loop must exclude a tool the SAME way the paste loop
  # excludes github (connectors D77/D82). Without the oauth-loop fix "linear oauth"
  # leaks here and the agreeing catalog+bridge is misreported as drift below.
  if grep -q '^linear ' <<<"$agree_set"; then
    echo "SELFTEST FAIL: a tool-direction OAUTH connector leaked into the channel connectable set"; return 1
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

  # ── TOOL-SET cases (variant B, D100) ──────────────────────────────────────
  #
  # (a) The channel set is BYTE-UNCHANGED by the presence of a @tool_providers
  #     block: the tool entries (github/linear) must NEVER leak into the CHANNEL
  #     set. This is the exact regression the separate-block design prevents.
  if grep -Eq '^(github|linear) ' <<<"$cat_set"; then
    echo "SELFTEST FAIL: a @tool_providers entry leaked into the CHANNEL set"; return 1
  fi
  if [ "$cat_set" != "$(printf 'discord paste\nslack oauth\ntelegram paste')" ]; then
    echo "SELFTEST FAIL: the @tool_providers block perturbed the channel set"
    echo "  channel set: [$(flat "$cat_set")]"
    return 1
  fi

  local cat_tool_set agree_tool_set drop_tool_set
  cat_tool_set="$(extract_catalog_tools "$tmp/catalog.ex")"
  agree_tool_set="$(extract_bridge_tools "$tmp/agree/connectors" "$tmp/agree/oauth")"

  if [ -z "$cat_tool_set" ] || [ -z "$agree_tool_set" ]; then
    echo "SELFTEST FAIL: tool extraction produced an empty set"; return 1
  fi
  # (b) Agreeing tool sets are GREEN. github (paste tool) + linear (oauth tool)
  #     must match on BOTH sides.
  if [ "$cat_tool_set" != "$agree_tool_set" ]; then
    echo "SELFTEST FAIL: an agreeing catalog+bridge TOOL set was reported as drift"
    echo "  catalog tools: [$(flat "$cat_tool_set")]"
    echo "  bridge tools:  [$(flat "$agree_tool_set")]"
    return 1
  fi

  # (c) A DROPPED tool entry REDS: a catalog that removes linear from
  #     @tool_providers while linear-oauth.ts still exists on the bridge must be
  #     caught (the tool dual of the dropped-channel-member case above).
  cat > "$tmp/catalog_drop_tool.ex" <<'EOF'
  @tool_providers [
    %{
      id: "github",
      connect_mode: :paste,
      direction: :tool
    }
  ]
EOF
  drop_tool_set="$(extract_catalog_tools "$tmp/catalog_drop_tool.ex")"
  if [ "$drop_tool_set" = "$agree_tool_set" ]; then
    echo "SELFTEST FAIL: a dropped TOOL entry went undetected"; return 1
  fi

  # ── END-TO-END ARMS: re-invoke "$0" so BOTH verdict comparisons and all
  # four empty-set fail-closed arms live inside the tripwire, not a fork of
  # it. Everything above exercises only the extractors; the real
  # CATALOG_SET/BRIDGE_SET and TOOL comparisons plus the empty-set exits
  # could be disarmed while every arm above stayed green (the
  # selftest-reimplements-the-scan defect this gate copied from its model,
  # cgsi-s3 class). Every arm asserts the EXIT CODE and its own message.
  run_gate() { # catalog-ex connectors-dir oauth-dir
    CONNECTORS_CATALOG_EX="$1" CONNECTORS_CATALOG_CONNECTORS_DIR="$2" \
      CONNECTORS_CATALOG_OAUTH_DIR="$3" bash "$0"
  }
  local out rc
  set +e
  out="$(run_gate "$tmp/catalog.ex" "$tmp/agree/connectors" "$tmp/agree/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "SELFTEST FAIL: an agreeing catalog+bridge exited $rc end-to-end, expected 0 — $out"; return 1
  fi
  case "$out" in *"PASS"*) ;; *) echo "SELFTEST FAIL: the agreeing pair did not print PASS end-to-end"; return 1 ;; esac

  set +e
  out="$(run_gate "$tmp/catalog.ex" "$tmp/drift/connectors" "$tmp/drift/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "SELFTEST FAIL: a dropped connect member exited $rc end-to-end, expected 1 — the CHANNEL verdict comparison is disarmed"; return 1
  fi
  case "$out" in *"connectable-provider DRIFT"*) ;; *) echo "SELFTEST FAIL: the channel-drift red did not come from the DRIFT verdict"; return 1 ;; esac

  # A catalog whose @tool_providers dropped linear while the bridge still ships
  # linear-oauth.ts: the CHANNEL sets agree, so only the TOOL verdict can red.
  sed '/id: "linear"/,/^    }$/d' "$tmp/catalog.ex" | sed 's/^    },$/    }/' > "$tmp/catalog_tooldrift.ex"
  grep -q 'id: "linear"' "$tmp/catalog_tooldrift.ex" \
    && { echo "SELFTEST FAIL: the tool-drift fixture still carries linear — this arm would prove nothing"; return 1; }
  set +e
  out="$(run_gate "$tmp/catalog_tooldrift.ex" "$tmp/agree/connectors" "$tmp/agree/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "SELFTEST FAIL: a dropped TOOL entry exited $rc end-to-end, expected 1 — the TOOL verdict comparison is disarmed"; return 1
  fi
  case "$out" in *"TOOL-connector DRIFT"*) ;; *) echo "SELFTEST FAIL: the tool-drift red did not come from the TOOL DRIFT verdict — $out"; return 1 ;; esac

  # The four fail-closed empties, one at a time so each red is attributable.
  : > "$tmp/catalog_empty.ex"
  set +e
  out="$(run_gate "$tmp/catalog_empty.ex" "$tmp/agree/connectors" "$tmp/agree/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "SELFTEST FAIL: an EMPTY channel catalog exited $rc end-to-end, expected 1 — the catalog empty-set arm is disarmed"; return 1
  fi
  case "$out" in *"no connectable providers parsed from"*) ;; *) echo "SELFTEST FAIL: the empty-catalog red did not come from its own arm"; return 1 ;; esac

  mkdir -p "$tmp/emptydirs/connectors" "$tmp/emptydirs/oauth"
  set +e
  out="$(run_gate "$tmp/catalog.ex" "$tmp/emptydirs/connectors" "$tmp/emptydirs/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "SELFTEST FAIL: an EMPTY bridge tree exited $rc end-to-end, expected 1 — the bridge empty-set arm is disarmed"; return 1
  fi
  case "$out" in *"no connectable providers parsed from"*) ;; *) echo "SELFTEST FAIL: the empty-bridge red did not come from its own arm"; return 1 ;; esac

  # BOTH sides empty — the composite the single-side arms cannot see. A
  # neutered empty-exit on ONE side degrades to the drift verdict (empty vs
  # non-empty still reds, misattributed); neuter them on BOTH sides and
  # empty == empty sails through BOTH comparisons as a vacuous PASS over a
  # completely unparsed world. Measured before this arm existed: all four
  # exits stripped -> rc 0 PASS.
  set +e
  out="$(run_gate "$tmp/catalog_empty.ex" "$tmp/emptydirs/connectors" "$tmp/emptydirs/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "SELFTEST FAIL: an ENTIRELY empty world exited $rc end-to-end, expected 1 — empty==empty scans vacuously green (the empty-set arms are disarmed)"; return 1
  fi

  # Channel agreement with NO tool block: the catalog-tool empty arm must red.
  awk '/@tool_providers/{exit} {print}' "$tmp/catalog.ex" > "$tmp/catalog_notools.ex"
  set +e
  out="$(run_gate "$tmp/catalog_notools.ex" "$tmp/agree/connectors" "$tmp/agree/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "SELFTEST FAIL: a MISSING @tool_providers block exited $rc end-to-end, expected 1 — the catalog tool empty-set arm is disarmed"; return 1
  fi
  case "$out" in *"no tool providers parsed from"*) ;; *) echo "SELFTEST FAIL: the missing-tool-block red did not come from its own arm"; return 1 ;; esac

  # Channel agreement with NO tool files on the bridge: the bridge-tool empty
  # arm must red. Copy the agree tree minus github/linear.
  mkdir -p "$tmp/nootool/connectors" "$tmp/nootool/oauth"
  for src in "$tmp/agree/connectors/telegram.ts" "$tmp/agree/connectors/discord.ts" "$tmp/agree/connectors/gateway.ts"; do
    cp "$src" "$tmp/nootool/connectors/"
  done
  cp "$tmp/agree/oauth/slack-oauth.ts" "$tmp/nootool/oauth/"
  set +e
  out="$(run_gate "$tmp/catalog.ex" "$tmp/nootool/connectors" "$tmp/nootool/oauth" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "SELFTEST FAIL: a bridge with NO tool connectors exited $rc end-to-end, expected 1 — the bridge tool empty-set arm is disarmed"; return 1
  fi
  case "$out" in *"no tool providers parsed from"*) ;; *) echo "SELFTEST FAIL: the no-tool-bridge red did not come from its own arm"; return 1 ;; esac

  echo "selftest OK: agree→green, dropped connect member→red, nil mode excluded, tool direction excluded (paste + oauth); tool set: agree→green, @tool_providers channel-neutral, dropped tool entry→red; END-TO-END re-invocation: both verdicts and all four empty-set fail-closed arms assert exit codes"
}

# Refuse an argument this gate does not understand. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "connectors-catalog-drift-check: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

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

# ── TOOL SET (variant B) — the OUTBOUND direction, checked INDEPENDENTLY ──────
CATALOG_TOOL_SET="$(extract_catalog_tools "$CATALOG_EX")"
BRIDGE_TOOL_SET="$(extract_bridge_tools "$CONNECTORS_DIR" "$OAUTH_DIR")"

# Empty = the extractor found nothing (block moved / all tool files renamed), NOT
# agreement — fail closed. The catalog ships EXACTLY two tool providers today, so
# an empty tool set is always a broken anchor.
if [ -z "$CATALOG_TOOL_SET" ]; then
  echo "FAIL: no tool providers parsed from $CATALOG_EX (@tool_providers block moved or renamed?)"; exit 1
fi
if [ -z "$BRIDGE_TOOL_SET" ]; then
  echo "FAIL: no tool providers parsed from $CONNECTORS_DIR / $OAUTH_DIR (a direction:\"tool\" connect: member or tool *-oauth.ts moved or renamed?)"; exit 1
fi

if [ "$CATALOG_TOOL_SET" != "$BRIDGE_TOOL_SET" ]; then
  only_catalog="$(comm -23 <(printf '%s\n' "$CATALOG_TOOL_SET") <(printf '%s\n' "$BRIDGE_TOOL_SET") | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  only_bridge="$(comm -13 <(printf '%s\n' "$CATALOG_TOOL_SET") <(printf '%s\n' "$BRIDGE_TOOL_SET") | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  echo "FAIL: TOOL-connector DRIFT — the Elixir catalog and the bridge registry disagree (connectors D99/D100)"
  echo "  $CATALOG_EX @tool_providers declares [$(flat "$CATALOG_TOOL_SET")]"
  echo "  but the bridge implements [$(flat "$BRIDGE_TOOL_SET")]"
  [ -n "$only_catalog" ] && echo "  catalog claims, bridge lacks:  $only_catalog"
  [ -n "$only_bridge" ]  && echo "  bridge implements, catalog omits: $only_bridge"
  echo "  → reconcile catalog.ex @tool_providers connect_mode with the bridge's direction:\"tool\" connect: member / tool *-oauth.ts callback"
  exit 1
fi

echo "connectors-catalog-drift-check: PASS — channel providers agree [$(flat "$CATALOG_SET")]; tool providers agree [$(flat "$CATALOG_TOOL_SET")]"
