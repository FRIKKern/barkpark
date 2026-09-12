#!/usr/bin/env bash
# Does `fetch-fixtures.sh` with no arguments still cover the whole panel?
#
#   bash tooling/paper-excellence/rig/fixture-list-check.sh
#
# Cheap, hermetic, no network, no browser — `gate.sh` runs it before the first
# render, so the advisory paper-rig workflow answers this question on every
# pull request that touches rig/**.
#
# WHY IT EXISTS. A refresh tool whose slug list is typed by hand is a snapshot
# of the panel on the day it was typed, and the panel keeps growing:
# `eight-minute-erasure` drifted in 2026-08-17 purely by being absent from that
# array, and `agent-flight-recorder-charter` was absent from it again on
# 2026-09-11 (task-15d30569241d3542). `fetch-fixtures.sh` now DERIVES the list;
# this check is what stops it being hand-written back, and what stops a new
# fixture landing without the provenance key the derivation reads.
#
# TWO ASSERTIONS, and they fail for different reasons:
#
#   1. PARTITION — every `fixtures/*.json` carries exactly one of `source_rev`
#      (published, refreshable) or `_source` (authored, no live document). A
#      fixture with neither would be silently dropped from a bare refresh —
#      which is the original drift, one level up.
#   2. AGREEMENT — `fetch-fixtures.sh --list` equals the published set derived
#      HERE. The two derivations are deliberately written against different
#      runtimes (that one in python3, this one in node) so this is a second
#      reading of the fixtures and not a re-run of the first.
#
# Mutation-proved 2026-09-12 (task-15d30569241d3542, worktree
# studio/rig-fixture-list), three ways:
#
#   unperturbed                     exit 0 — "7 published, 2 authored, 9 fixtures"
#   fetch-fixtures.sh hand-listed   exit 1 — "default slug list disagrees …
#     (agent-flight-recorder-charter                   only in the derived set:
#      dropped, as in the pre-fix file)                agent-flight-recorder-charter"
#   a fixture with neither key      exit 1 — "must carry exactly one of
#     (fixtures/zz-probe.json)                          `source_rev` … or `_source`"
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DERIVED="$(node -e '
const fs = require("fs");
const path = require("path");
const dir = process.argv[1];
const published = [];
let authored = 0;
for (const name of fs.readdirSync(dir).sort()) {
  if (!name.endsWith(".json")) continue;
  const doc = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"));
  const isPublished = Object.prototype.hasOwnProperty.call(doc, "source_rev");
  const isAuthored = Object.prototype.hasOwnProperty.call(doc, "_source");
  if (isPublished === isAuthored) {
    console.error(
      "rig/fixture-list: fixtures/" + name + " must carry exactly one of " +
      "`source_rev` (published) or `_source` (authored) — it carries " +
      (isPublished ? "both" : "neither")
    );
    process.exit(1);
  }
  if (isPublished) published.push(name.slice(0, -".json".length));
  else authored++;
}
process.stderr.write(
  "rig/fixture-list: " + published.length + " published, " + authored +
  " authored, " + (published.length + authored) + " fixtures\n"
);
process.stdout.write(published.join("\n") + "\n");
' "$RIG_DIR/fixtures")"

ACTUAL="$(bash "$RIG_DIR/fetch-fixtures.sh" --list)"

if [ "$DERIVED" != "$ACTUAL" ]; then
  echo "rig/fixture-list: FAIL — fetch-fixtures.sh's default slug list disagrees with fixtures/*.json" >&2
  comm -23 <(printf '%s\n' "$DERIVED") <(printf '%s\n' "$ACTUAL") \
    | sed 's/^/rig\/fixture-list:   only in the derived set: /' >&2
  comm -13 <(printf '%s\n' "$DERIVED") <(printf '%s\n' "$ACTUAL") \
    | sed 's/^/rig\/fixture-list:   only in fetch-fixtures.sh: /' >&2
  echo "rig/fixture-list:   the default list must be DERIVED from fixtures/*.json, never typed" >&2
  exit 1
fi

echo "rig/fixture-list: OK — fetch-fixtures.sh covers every published fixture"
