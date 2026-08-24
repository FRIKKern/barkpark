#!/usr/bin/env bash
# proof.sh — thin wrapper over proof.mjs, matching fixtures/cssom-floor/proof.sh.
#
# The proof needs a real browser (the defect is a computed-opacity read that only
# a rendering engine performs), so the work is in proof.mjs. This exists so the
# fixtures directory has the same entry point as its sibling.
#
#   bash cloud/priv/static/__preview__/fixtures/ready-host-paint/proof.sh
#   CHROME=/path/to/chrome bash …/proof.sh
#
# exit 0 = every direction landed where it should
# exit 1 = the floor behaved wrongly (a direction failed)
# exit 2 = no browser — an ENVIRONMENT refusal, never a failed proof
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$DIR/proof.mjs" "$@"
