#!/usr/bin/env bash
# pds-blind-spot.sh — PDS-D633's meter blind spot, as ONE constant instruments
# SOURCE, never as prose a copy-paste can drop.
#
# WHY THIS FILE EXISTS AT ALL. PDS-D633 ends with an obligation: "Every number
# this epic prints from a meter must carry the blind-spot sentence in the
# instrument's own @moduledoc AND its printed output, not in prose a copy-paste
# can drop." The wave-43 verifier then named the risk in its own finding: that
# obligation is a DISCIPLINE, not a mechanism — adopt it as prose and wave 44
# restates it. So the sentence lives here, once, and every metering instrument
# reaches it by reference:
#
#   * bash instruments SOURCE this file and call `pds_blind_spot_note`;
#   * scripts/pds-elixir-receipt-census.exs and tooling/pds/blind-spot.mjs hold
#     a literal in their own language, and `scripts/pds-blind-spot-check.sh`
#     REDS if that literal has drifted one byte from `$PDS_BLIND_SPOT` here.
#     Cross-language, a byte-compared copy is the closest thing to one constant
#     a shell file and a BEAM script can share, and the comparison is the
#     mechanism — not the good intentions of whoever edits one of them.
#
# THIS FILE IS SOURCED, NOT EXECUTED, BY INSTRUMENTS. It sets no shell options,
# runs nothing, reads nothing, and writes nothing, so sourcing it under
# `set -euo pipefail` changes no caller's behaviour. Run directly it prints the
# constants (`--sentence`, `--placement`, or both), which is how a non-bash
# reader can obtain the canonical text without retyping it.
#
# NEVER `grep -q` THIS FILE'S OUTPUT AND READ THE PIPELINE'S rc. With pipefail
# on, grep closes the pipe on its first match and the SIGPIPE'd writer decides
# the rc — the failure mode that once made a five-locale host report "no locale
# installed". Read to EOF, or match on a captured string.

# ---------------------------------------------------------------------------
# THE SENTENCE, VERBATIM (PDS-D633). Byte-identical to `@blind_spot` in
# api/test/barkpark_web/live/studio/pds_w43_caps_derive_cost_test.exs, which is
# where wave 43 first shipped it. One line on purpose: a wrapped copy is a copy
# that drifts on the next re-wrap.
# ---------------------------------------------------------------------------
PDS_BLIND_SPOT=":erlang.statistics(:runtime) is a VM-GLOBAL sum of BEAM scheduler + async-thread CPU. It is accurate to <1% for pure in-BEAM work, blind to port children (2.58 s read as 6 ms), blind to I/O wait and to Postgres' own CPU, floored at 1 ms, and inflated by any concurrent process in the same VM (5.0x under 8 siblings)."

# ---------------------------------------------------------------------------
# THE PLACEMENT RULE (PDS-D633), which is the half a reader needs in order to
# know whether the figure beside it was taken from a meter that could see the
# cost at all. Stated here AND, per PDS-D633's own reasoning, again in each
# meter's own source beside the measuring call, tagged `PDS-BLIND-SPOT-METER:`
# so the check can find it. Two copies of a rule that must not drift is exactly
# the shape this file exists to refuse — which is why the check compares them.
# ---------------------------------------------------------------------------
PDS_BLIND_SPOT_PLACEMENT="PLACEMENT (PDS-D633): an instrument's price is measured with the OS meter around a SHELL (/usr/bin/time -l bash -c '<instrument>') or bash's times builtin -- proven to see user 2,18 / children 0m2.310s where the BEAM-wrapped meter saw 0.19 -- NEVER from inside a BEAM parent. For a regression ratchet under a required gate the unit is Process.info(pid, :reductions), byte-identical (2 500 395) at 0, 4 and 8 noise processes where milliseconds moved 5x."

# ---------------------------------------------------------------------------
# pds_blind_spot_note <meter placement this instrument used> [figure-label]
#
# Prints the sentence, the meter THIS instrument actually used, and the rule the
# placement is answerable to. $1 is REQUIRED and is not defaulted to something
# plausible: a figure whose meter is not named is not a measurement, and a
# silently-defaulted meter label is the fabrication this whole apparatus is
# about. Prints to stdout so it lands on the instrument's own output path.
# ---------------------------------------------------------------------------
pds_blind_spot_note() {
  local meter="${1:-}"
  local label="${2:-}"
  if [ -z "$meter" ]; then
    meter='UNDECLARED — the caller named no meter, so this figure has no provenance and must not be quoted'
  fi
  if [ -n "$label" ]; then
    printf 'METER BLIND SPOT (PDS-D633) — for: %s\n' "$label"
  else
    printf 'METER BLIND SPOT (PDS-D633)\n'
  fi
  printf '  %s\n' "$PDS_BLIND_SPOT"
  printf '  meter: %s\n' "$meter"
  printf '  %s\n' "$PDS_BLIND_SPOT_PLACEMENT"
}

# Direct execution: emit the constants for a reader that is not a bash shell.
# `return` first so a `source` of this file never falls into the dispatch.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  case "${1:---both}" in
    --sentence)  printf '%s\n' "$PDS_BLIND_SPOT" ;;
    --placement) printf '%s\n' "$PDS_BLIND_SPOT_PLACEMENT" ;;
    --both)      printf '%s\n%s\n' "$PDS_BLIND_SPOT" "$PDS_BLIND_SPOT_PLACEMENT" ;;
    *)
      printf 'pds-blind-spot.sh: unknown argument %s (accepted: --sentence --placement --both)\n' "$1" >&2
      exit 2
      ;;
  esac
fi
