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
# Exit codes — a failed READ must never look like a genuine "no plugins":
#   0  matrix built (possibly [] / empty=true, when the root exists but no
#      plugin.json declares a top-level "node" key — a real, honest zero).
#   4  HARNESS FAILURE: PLUGINS_ROOT does not exist. This used to emit
#      [] / empty=true at exit 0, so a moved or renamed plugins tree made
#      plugin-node.yml skip every per-plugin job and end GREEN. The
#      consumer (.github/workflows/plugin-node.yml `discover` step, no
#      continue-on-error) turns this exit into a failed job, and the
#      `plugin` job that `needs: discover` is then never dispatched.

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

EXIT_MISSING_ROOT=4

if [ ! -d "$PLUGINS_ROOT" ]; then
  echo "CANNOT READ: PLUGINS_ROOT $PLUGINS_ROOT missing" >&2
  exit "$EXIT_MISSING_ROOT"
fi

# Collect manifests with a top-level "node" key. jq is preinstalled on
# ubuntu-latest runners; locally it is required.
# `mapfile` is bash 4+; macOS ships bash 3.2, where it made this script — and
# therefore its own selftest — die at exit 127 the moment PLUGINS_ROOT existed.
MANIFESTS=()
while IFS= read -r manifest_path; do
  MANIFESTS+=("$manifest_path")
done < <(find "$PLUGINS_ROOT" -mindepth 2 -maxdepth 2 -name "plugin.json" 2>/dev/null | sort)

ENTRIES="[]"
# ${a[@]+"${a[@]}"} — an empty array is an unbound variable under set -u in 3.2.
for manifest in ${MANIFESTS[@]+"${MANIFESTS[@]}"}; do
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
