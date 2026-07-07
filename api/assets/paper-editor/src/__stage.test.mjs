// __stage.test.mjs — the standalone runner for the `stage` WIDGET smoke suite
// (loop-epic/pipeline-widget). Imports the shared harness-registered checks in
// ./smoke/stage.mjs (round-trip zero-ops + non-vacuous mutation ops + removals-land +
// section fine-grained patch + source-verbatim + slots-plain-text + echo), then
// report()s the aggregate pass/fail + exit code. Also folded into ./__smoke.mjs so
// `npm test` runs it in the aggregate. Run: node src/__stage.test.mjs
import "./smoke/stage.mjs";
import { report } from "./smoke/harness.mjs";

report();
