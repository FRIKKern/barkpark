// __note.test.mjs — package-owned runner for pure-Node note projection,
// round-trip and op-strategy checks in ./smoke/note.mjs.
// Mounted schema and NodeView checks run in ./__note_mounted.test.mjs with
// ./note-mounted-harness.mjs. Barkpark LiveView-hook and live-shell CSS checks
// run separately in ../paper-editor-host-tests/note.test.mjs.
// report() emits the aggregate pass/fail and exit code. These pure checks are
// also imported by ./__smoke.mjs; npm test discovers both package runners.
// Run: node src/__note.test.mjs
import "./smoke/note.mjs";
import { report } from "./smoke/harness.mjs";

report();
