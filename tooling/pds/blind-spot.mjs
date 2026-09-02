// blind-spot.mjs — PDS-D633's meter blind spot, for the JS side of the epic.
//
// THE CANONICAL TEXT IS scripts/pds-blind-spot.sh (`$PDS_BLIND_SPOT`). This is a
// COPY, and the copy is CHECKED: scripts/pds-blind-spot-check.sh reds if this
// literal has drifted one byte from the shell constant. A byte-compared copy is
// as close to one constant as a POSIX shell file and an ES module get without a
// runtime file read on every render, and the comparison — not anyone's
// discipline — is what makes the obligation a mechanism instead of a habit.
//
// WHY THIS EXISTS AT ALL. tooling/pds/adjudicate.mjs meters its own execution
// budget with Date.now() and tooling/pds/verdict.mjs prints the result as a
// millisecond figure on the line the board reads. A millisecond figure with no
// meter named beside it is exactly the thing PDS-D633 is about.

export const PDS_BLIND_SPOT =
  ":erlang.statistics(:runtime) is a VM-GLOBAL sum of BEAM scheduler + " +
  "async-thread CPU. It is accurate to <1% for pure in-BEAM work, blind to port " +
  "children (2.58 s read as 6 ms), blind to I/O wait and to Postgres' own CPU, " +
  "floored at 1 ms, and inflated by any concurrent process in the same VM (5.0x " +
  "under 8 siblings).";

export const PDS_BLIND_SPOT_PLACEMENT =
  "PLACEMENT (PDS-D633): an instrument's price is measured with the OS meter " +
  "around a SHELL (/usr/bin/time -l bash -c '<instrument>') or bash's times " +
  "builtin -- NEVER from inside a BEAM parent. For a regression ratchet under a " +
  "required gate the unit is Process.info(pid, :reductions).";

// The meter THIS toolchain actually uses, named where its figure is printed.
export const PDS_JS_METER =
  "Date.now(), WALL CLOCK inside this Node process, around the recipe-execution " +
  "loop only — an OS-level clock outside every BEAM (PDS-D633 placement (a)). It " +
  "is a BUDGET ODOMETER, not a price: it decides when to stop spending, and it " +
  "charges every child process's WAITING as well as its work. PDS-D605 forbids a " +
  "wall-clock second standing in for CPU, so nothing here says what a rerun COST.";

// Rendered beside the figure, on the instrument's own output path.
export function blindSpotNote(meter = PDS_JS_METER) {
  return [
    "  blind spot    " + PDS_BLIND_SPOT,
    "  meter         " + meter,
    "  " + PDS_BLIND_SPOT_PLACEMENT,
  ];
}
