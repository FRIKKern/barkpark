#!/usr/bin/env bash
# D-NUMBER ARBITER for .claude/workflows/bp-deploy-reliability-charter.md.
#
# THIS FILE CONTAINS NO ARBITER LOGIC ON PURPOSE. It is three variable bindings
# in front of scripts/pds-record-parity.sh, which already owns the definition
# lens, the mkdir-atomic allocation lock, the SEED semantics and the
# UNRESERVED-MINT refusal. A SECOND implementation is the outcome to avoid: two
# arbiters can drift, and the lens over there has drifted once already
# (PDS-D679 — a heading-blind copy manufactured six phantom citations). If the
# deploy charter needs a lens change, it changes THERE, once, for both charters.
#
#   bash deploy/d-number-arbiter.sh --allocate-d 1 --for "task-… <who>"
#       Reserves the next number AND PRINTS IT. Run this BEFORE you write the
#       decision, then commit the ledger row in the same PR as the charter edit.
#
#   bash deploy/d-number-arbiter.sh --check-alloc
#       rc=0 PARITY — every number the charter defines above the seed was
#             reserved first.
#       rc=1 DIVERGENT — a number was minted by reading the charter. Named.
#       rc=2 UNCHECKED — the arm could not look. NOT a pass.
#
# WHY READING THE CHARTER CANNOT WORK, so nobody re-litigates it: on 2026-09-16
# two PRs an hour apart both read the charter, both correctly found D613 as the
# maximum, and both minted D614. The document is a lagging record of what has
# LANDED; it cannot express what is IN FLIGHT. The reservation can.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "d-number-arbiter: cannot cd to the repo root" >&2; exit 2; }

exec bash scripts/pds-record-parity.sh \
  --prefix D \
  --charter .claude/workflows/bp-deploy-reliability-charter.md \
  --alloc-ledger deploy/d-number-reservations.tsv \
  "$@"
