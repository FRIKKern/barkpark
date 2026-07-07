// __cards.test.mjs — the standalone runner for the STEP 4 card WIDGET smoke suite
// (loop-epic/split-cards). Imports the shared harness-registered checks in
// ./smoke/cards.mjs (round-trip zero-ops + non-vacuous mutation ops + removals-land +
// grid-section fine-grained patch + echo), then report()s the aggregate pass/fail +
// exit code. Also folded into the ./__smoke.mjs index so `npm test` runs it in the
// aggregate. Run: node src/__cards.test.mjs
import "./smoke/cards.mjs";
import { report } from "./smoke/harness.mjs";

report();
