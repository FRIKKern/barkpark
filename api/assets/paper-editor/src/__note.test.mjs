// __note.test.mjs — the standalone runner for the notes-grid split `note` WIDGET
// smoke suite. Imports the shared harness-registered checks in ./smoke/note.mjs
// (projection + round-trip zero-ops + non-vacuous per-field mutation ops + lead-removal
// lands + insert + echo), then report()s the aggregate pass/fail + exit code. Also
// folded into the ./__smoke.mjs index so `npm test` runs it in the aggregate.
// Run: node src/__note.test.mjs
import "./smoke/note.mjs";
import { report } from "./smoke/harness.mjs";

report();
