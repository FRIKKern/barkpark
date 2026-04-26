#!/usr/bin/env bash
# Phase 2 / WI4 — Build the dynamic matrix for plugin-node.yml.
#
# Scans api/priv/plugins/*/plugin.json for a top-level "node" object and emits
# a JSON array on stdout (and to GITHUB_OUTPUT when running in Actions).
#
# Each entry has the shape:
#   { "plugin": "<dirname>", "dir": "<path>", "node": "<engine>",
#     "lint": <bool>, "typecheck": <bool> }
#
# Env:
#   PLUGINS_ROOT  — override the root scan path (default api/priv/plugins).
#   GITHUB_OUTPUT — when set, also writes `matrix=` and `empty=` lines.
#
# Exit 0 in all expected cases, including "no plugins found".

set -euo pipefail

PLUGINS_ROOT="${PLUGINS_ROOT:-api/priv/plugins}"

emit() {
  local matrix_json="$1"
  local empty="$2"
  echo "$matrix_json"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "matrix=${matrix_json}"
      echo "empty=${empty}"
    } >> "$GITHUB_OUTPUT"
  fi
}

if [ ! -d "$PLUGINS_ROOT" ]; then
  emit "[]" "true"
  exit 0
fi

# Collect manifests with a top-level "node" key. jq is preinstalled on
# ubuntu-latest runners; locally it is required.
mapfile -t MANIFESTS < <(find "$PLUGINS_ROOT" -mindepth 2 -maxdepth 2 -name "plugin.json" 2>/dev/null | sort)

ENTRIES="[]"
for manifest in "${MANIFESTS[@]}"; do
  has_node=$(jq 'has("node")' "$manifest")
  if [ "$has_node" != "true" ]; then
    continue
  fi
  dir=$(dirname "$manifest")
  plugin=$(basename "$dir")
  node_version=$(jq -r '.node.engines.node // "20"' "$manifest")
  lint=$(jq -r '.node.scripts.lint != null' "$manifest")
  typecheck=$(jq -r '.node.scripts.typecheck != null' "$manifest")
  entry=$(jq -nc \
    --arg plugin "$plugin" \
    --arg dir "$dir" \
    --arg node "$node_version" \
    --argjson lint "$lint" \
    --argjson typecheck "$typecheck" \
    '{plugin:$plugin, dir:$dir, node:$node, lint:$lint, typecheck:$typecheck}')
  ENTRIES=$(jq -c ". + [${entry}]" <<<"$ENTRIES")
done

if [ "$(jq 'length' <<<"$ENTRIES")" -eq 0 ]; then
  emit "[]" "true"
else
  emit "$ENTRIES" "false"
fi
