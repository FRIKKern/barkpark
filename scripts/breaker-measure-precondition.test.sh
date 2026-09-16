#!/usr/bin/env bash
# breaker-measure-precondition.test.sh — CI tenancy for
# scripts/breaker-measure-precondition.sh's arms.
#
# The arms live in the script itself (--selftest) because they are fixture-only:
# no network, no clock, no live repo state. This wrapper exists so the census in
# scripts/selftest-wiring-census.sh can SEE them — a self-test nothing runs is a
# self-test that goes stale the first time someone edits the detector.
#
# It deliberately does NOT run the script's --report mode. That mode reads the
# LIVE ci-measure.sh and today reports NOT YET MEASURABLE (rc 1) because
# breaker_verdict() cannot name OWNERSHIP-UNDETERMINED. Wiring the live report
# into CI would red every PR over a known, filed gap.
set -u
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
bash scripts/breaker-measure-precondition.sh --selftest
