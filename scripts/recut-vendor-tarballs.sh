#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Barkpark contributors
#
# Re-cut the vendored starter SDK tarballs. This is the remedy
# scripts/check-vendor-freshness.mjs points at when it reds STALE-SOURCE.
#
# bash, not zsh, on purpose: zsh word-splits differently and this script feeds
# paths through command substitution.
#
# What it does, in order:
#   1. builds js/packages/{core,react}
#   2. packs each with PNPM — never npm. `npm pack` in this monorepo emits
#      `workspace:^` dependency specifiers, which are uninstallable outside the
#      workspace, so an npm-packed tarball breaks `npm ci` in the templates.
#   3. copies both tarballs into BOTH templates' vendor/ dirs
#   4. repins each template lockfile's `integrity` for the two vendored entries.
#      A bare tarball swap leaves the old sha512 pin and `npm ci` then fails
#      with EINTEGRITY (or, worse, a warm cache reinstalls the OLD bytes).
#      Only the two integrity strings are touched — a full `npm install`
#      re-resolves every transitive dependency and buries the SDK bump in a
#      2000-line lockfile diff nobody reviews.
#   5. re-stamps templates/VENDOR-STAMP.json
#   6. runs the freshness gate, which must now be green
#
# After this, run `npm ci` in each template if you want node_modules to match.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES=(templates/search-starter templates/astro-search-starter)
PACK_DIR="$(mktemp -d)"
trap 'rm -rf "$PACK_DIR"' EXIT

if ! command -v pnpm >/dev/null 2>&1; then
  echo "recut-vendor-tarballs: pnpm is required (npm pack emits workspace:^ specifiers)" >&2
  exit 1
fi

echo "==> building js/packages/core and js/packages/react"
(cd "$REPO_ROOT/js/packages/core" && pnpm build >/dev/null)
(cd "$REPO_ROOT/js/packages/react" && pnpm build >/dev/null)

echo "==> packing with pnpm"
(cd "$REPO_ROOT/js/packages/core" && pnpm pack --pack-destination "$PACK_DIR" >/dev/null)
(cd "$REPO_ROOT/js/packages/react" && pnpm pack --pack-destination "$PACK_DIR" >/dev/null)

CORE_TGZ="$(ls "$PACK_DIR"/barkpark-core-*.tgz)"
REACT_TGZ="$(ls "$PACK_DIR"/barkpark-react-*.tgz)"
echo "    core:  $(basename "$CORE_TGZ")"
echo "    react: $(basename "$REACT_TGZ")"

for tpl in "${TEMPLATES[@]}"; do
  echo "==> installing tarballs into $tpl/vendor"
  cp "$CORE_TGZ" "$REPO_ROOT/$tpl/vendor/barkpark-core.tgz"
  cp "$REACT_TGZ" "$REPO_ROOT/$tpl/vendor/barkpark-react.tgz"
done

echo "==> repinning lockfile integrity"
node - "$REPO_ROOT" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')

const root = process.argv[2]
const templates = ['templates/search-starter', 'templates/astro-search-starter']
const packages = [
  ['@barkpark/core', 'barkpark-core.tgz'],
  ['@barkpark/react', 'barkpark-react.tgz'],
]

for (const tpl of templates) {
  const lockPath = path.join(root, tpl, 'package-lock.json')
  const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'))
  let touched = 0
  for (const [name, tarball] of packages) {
    const bytes = fs.readFileSync(path.join(root, tpl, 'vendor', tarball))
    const integrity = 'sha512-' + crypto.createHash('sha512').update(bytes).digest('base64')
    const entry = lock.packages && lock.packages['node_modules/' + name]
    if (!entry) throw new Error(`${tpl}: lockfile has no node_modules/${name} entry — refusing to guess`)
    entry.integrity = integrity
    touched += 1
  }
  if (touched !== packages.length) throw new Error(`${tpl}: repinned ${touched} of ${packages.length}`)
  fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + '\n')
  console.log(`    ${tpl}: repinned ${touched} integrity values`)
}
NODE

echo "==> re-stamping templates/VENDOR-STAMP.json"
node "$REPO_ROOT/scripts/check-vendor-freshness.mjs" --write

echo "==> verifying"
node "$REPO_ROOT/scripts/check-vendor-freshness.mjs"
echo
echo "Re-cut complete. Run 'npm ci' inside each template to refresh node_modules."
