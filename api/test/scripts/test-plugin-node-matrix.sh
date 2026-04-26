#!/usr/bin/env bash
# Smoke test for build-plugin-node-matrix.sh.
# Run from repo root: bash api/test/scripts/test-plugin-node-matrix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/build-plugin-node-matrix.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required."
  exit 1
fi

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok  — $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

with_tmp_root() {
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  echo "$tmp"
}

# Case 1 — no plugins root => empty matrix.
echo "case: missing plugins root"
TMP=$(mktemp -d)
out=$(PLUGINS_ROOT="$TMP/does-not-exist" bash "$BUILDER")
assert_eq "matrix is empty array" "[]" "$out"
rm -rf "$TMP"

# Case 2 — plugins exist but none declare "node" => empty matrix.
echo "case: plugins without node capability"
TMP=$(mktemp -d)
mkdir -p "$TMP/onixedit"
cat > "$TMP/onixedit/plugin.json" <<'EOF'
{"name":"onixedit","version":"0.1.0"}
EOF
out=$(PLUGINS_ROOT="$TMP" bash "$BUILDER")
assert_eq "no node => empty" "[]" "$out"
rm -rf "$TMP"

# Case 3 — single plugin declares node + scripts => matrix entry emitted.
echo "case: plugin with node capability"
TMP=$(mktemp -d)
mkdir -p "$TMP/myplugin"
cat > "$TMP/myplugin/plugin.json" <<'EOF'
{
  "name": "myplugin",
  "version": "0.1.0",
  "node": {
    "engines": {"node": "22"},
    "scripts": {"lint": "eslint .", "typecheck": "tsc --noEmit"}
  }
}
EOF
out=$(PLUGINS_ROOT="$TMP" bash "$BUILDER")
plugin_name=$(jq -r '.[0].plugin' <<<"$out")
node_ver=$(jq -r '.[0].node' <<<"$out")
lint=$(jq -r '.[0].lint' <<<"$out")
typecheck=$(jq -r '.[0].typecheck' <<<"$out")
assert_eq "plugin name" "myplugin" "$plugin_name"
assert_eq "node version" "22" "$node_ver"
assert_eq "lint flag" "true" "$lint"
assert_eq "typecheck flag" "true" "$typecheck"
rm -rf "$TMP"

# Case 4 — node declared without scripts => flags false, default node 20.
echo "case: node declared without scripts"
TMP=$(mktemp -d)
mkdir -p "$TMP/bare"
cat > "$TMP/bare/plugin.json" <<'EOF'
{"name":"bare","version":"0.1.0","node":{}}
EOF
out=$(PLUGINS_ROOT="$TMP" bash "$BUILDER")
node_ver=$(jq -r '.[0].node' <<<"$out")
lint=$(jq -r '.[0].lint' <<<"$out")
typecheck=$(jq -r '.[0].typecheck' <<<"$out")
assert_eq "default node 20" "20" "$node_ver"
assert_eq "lint default false" "false" "$lint"
assert_eq "typecheck default false" "false" "$typecheck"
rm -rf "$TMP"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
