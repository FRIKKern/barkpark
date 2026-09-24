// sweep-predicate.test.mjs — the journey's self-clean predicate, both directions.
//
//   node --test tooling/studio-journey/sweep-predicate.test.mjs
//   node scripts/node-test-floor.mjs tooling/studio-journey/sweep-predicate.test.mjs
//
// WHY THIS FILE EXISTS (task-d582be9d064f35dc). journey.mjs deletes documents on
// a LIVE host. Until now the only thing that asserted the predicate doing it was
// the browser self-test — which needs Chrome, takes ninety seconds, and could
// not reproduce the defect at all, because its fixture never gave a draft a
// title and the real server does.
//
// THE DEFECT, in one line: the old predicate required the draft's title to be
// EMPTY or "Untitled", and this harness's own TYPE beat sets a title. A run that
// died after TYPE left a document no sweep could ever select again.
//
// EVERY DOCUMENT IN `LIVE` BELOW IS A REAL SHAPE, read off
// https://guerrilla.barkpark.cloud on 2026-09-22 with
// `filter[_id][eq]=<id>&perspective=drafts`. They are not invented, and their
// titles are the titles the deployment actually derived from the typed blocks.
// Raw readings: tooling/studio-journey/evidence-sweep/catalogue.json.

import test from "node:test";
import assert from "node:assert/strict";
import {
  sweepCandidate,
  harnessStamped,
  untitledTemplateShape,
  STAMP_FIELD,
  HARNESS_MARK,
  STALE_DEBRIS_MS,
} from "./journey.mjs";

const TPL = [
  { id: "tpl-title", type: "heading", level: 1, role: "title", locked: true, text: "" },
  { id: "tpl-body", type: "paragraph", content: [] },
];

/** The six drafts a night of killed runs left on guerrilla, as they read on the
 *  host. Five carry a journey-derived title; the sixth carries `null`. */
const LIVE = [
  { _id: "drafts.paper-8be087501234ae2d", _draft: true, _createdAt: "2026-09-22T06:29:01.217408Z", title: null, blocks: TPL },
  { _id: "drafts.paper-c113346aba4d66ab", _draft: true, _createdAt: "2026-09-22T06:18:33.005780Z", title: "journey paragraph MUCA9FZ6", blocks: TPL },
  { _id: "drafts.paper-0643af76eb6b633b", _draft: true, _createdAt: "2026-09-22T06:18:07.642356Z", title: "journey paragraph MUCA8WHGJOURNEY HEADING MUCA8WHGjourney paragraph MUCA8WHG", blocks: TPL },
  { _id: "drafts.paper-3a477d9b6918e824", _draft: true, _createdAt: "2026-09-22T06:17:48.067584Z", title: "journey paragraph MUCA8HNK", blocks: TPL },
  { _id: "drafts.paper-98e2223da8e80e75", _draft: true, _createdAt: "2026-09-22T06:07:10.973495Z", title: "journey paragraph MUC9UTIOJOURNEY HEADING MUC9UTIOjourney paragraph MUC9UTIO", blocks: TPL },
  { _id: "drafts.paper-b9a56007639bfd72", _draft: true, _createdAt: "2026-09-22T05:57:30.827813Z", title: "journey paragraph MUC9IDY5", blocks: TPL },
];
const TITLED_LIVE = LIVE.filter((d) => d.title !== null);

const NOW = Date.parse("2026-09-22T12:00:00.000Z");
const stamp = (over = {}) => ({ harness: HARNESS_MARK, run_id: "RUNA", host: "https://guerrilla.barkpark.cloud", stamped_at: "2026-09-22T06:00:00.000Z", ...over });
const at = (msAgo) => new Date(NOW - msAgo).toISOString();

// ── THE DEFECT, REPRODUCED AS A PREDICATE FACT ──────────────────────────────
test("the OLD title clause rejects every titled draft the harness's own TYPE beat produced", () => {
  // `since` is generous on purpose — the epoch, so the time clause cannot be
  // what rejects them. What rejects them is the title, and only the title.
  for (const d of TITLED_LIVE) {
    assert.equal(untitledTemplateShape(d, 0), false, `${d._id} (title=${JSON.stringify(d.title)}) was selectable by the title clause`);
  }
  assert.equal(TITLED_LIVE.length, 5, "five of the six catalogued drafts carry a journey-derived title");
});

// THE CONTROL FOR THE ASSERTION ABOVE. Without it, "the predicate said no" is
// indistinguishable from a predicate that says no to everything.
test("CONTROL — the same clause says YES to an untitled draft of the same shape", () => {
  const untitled = { ...LIVE[0], title: null };
  assert.equal(untitledTemplateShape(untitled, 0), true);
  assert.equal(untitledTemplateShape({ ...untitled, title: "Untitled" }, 0), true);
  assert.equal(untitledTemplateShape({ ...untitled, title: "  UNTITLED  " }, 0), true);
});

test("and the TIME clause alone already makes every leftover permanent, titled or not", () => {
  // drafts.paper-8be087501234ae2d is untitled AND template-shaped — the title
  // clause passes it. A LATER run still cannot reclaim it, because `since` is
  // always that run's own press. So a longer title vocabulary was never the fix.
  const untitledOne = LIVE[0];
  assert.equal(untitledTemplateShape(untitledOne, 0), true, "precondition: the title clause does pass it");
  assert.equal(untitledTemplateShape(untitledOne, NOW - 2000), false, "a later run's window excludes it");
});

// ── THE REPLACEMENT ─────────────────────────────────────────────────────────
test("a stamped draft is selected whatever its title, once its run is provably dead", () => {
  for (const d of LIVE) {
    const marked = { ...d, [STAMP_FIELD]: stamp({ run_id: "DEAD" }), _createdAt: at(STALE_DEBRIS_MS + 60_000) };
    assert.equal(harnessStamped(marked), true);
    assert.equal(sweepCandidate(marked, NOW, { runId: "MINE", now: NOW }), true, `${d._id} was not reclaimed by the stamp`);
  }
});

test("the run's OWN in-flight document is selected immediately — no age required", () => {
  const mine = { ...TITLED_LIVE[0], [STAMP_FIELD]: stamp({ run_id: "MINE" }), _createdAt: at(1000) };
  assert.equal(sweepCandidate(mine, NOW, { runId: "MINE", now: NOW }), true);
});

test("a CONCURRENT run's fresh document is NOT selected — the only guard arm 1 has", () => {
  const sibling = { ...TITLED_LIVE[0], [STAMP_FIELD]: stamp({ run_id: "SIBLING" }), _createdAt: at(5_000) };
  assert.equal(harnessStamped(sibling), true, "precondition: it IS stamped");
  assert.equal(sweepCandidate(sibling, NOW, { runId: "MINE", now: NOW }), false);
  // The boundary, from both sides, so the comparison cannot be inverted silently.
  const justInside = { ...sibling, _createdAt: at(STALE_DEBRIS_MS - 1) };
  const justOutside = { ...sibling, _createdAt: at(STALE_DEBRIS_MS + 1) };
  assert.equal(sweepCandidate(justInside, NOW, { runId: "MINE", now: NOW }), false);
  assert.equal(sweepCandidate(justOutside, NOW, { runId: "MINE", now: NOW }), true);
});

test("the mark is an EXACT match, not a truthy field — another harness's stamp is not ours", () => {
  const foreign = { ...TITLED_LIVE[0], [STAMP_FIELD]: { harness: "tooling/search-smoke/journey-smoke.mjs", run_id: "X" }, _createdAt: at(STALE_DEBRIS_MS + 60_000) };
  assert.equal(harnessStamped(foreign), false);
  assert.equal(sweepCandidate(foreign, NOW, { runId: "MINE", now: NOW }), false);
  const truthyJunk = { ...TITLED_LIVE[0], [STAMP_FIELD]: true, _createdAt: at(STALE_DEBRIS_MS + 60_000) };
  assert.equal(harnessStamped(truthyJunk), false);
});

// ── WHAT IT MUST NEVER TAKE ─────────────────────────────────────────────────
test("a human's paper is never selected — titled, old, authored, unstamped", () => {
  const human = {
    _id: "drafts.paper-humanwork", _draft: true, _createdAt: at(STALE_DEBRIS_MS * 10), title: "Q3 board notes",
    blocks: [...TPL, { id: "b3", type: "paragraph", content: [{ text: "real work" }] }],
  };
  assert.equal(sweepCandidate(human, 0, { runId: "MINE", now: NOW }), false);
  assert.equal(sweepCandidate(human, NOW, { runId: "MINE", now: NOW }), false);
});

test("an unstamped draft with MORE than the seeded template's blocks is never selected", () => {
  const authored = { _id: "drafts.paper-authored", _draft: true, _createdAt: at(1000), title: null, blocks: [...TPL, { id: "b3", type: "paragraph", content: [] }] };
  assert.equal(sweepCandidate(authored, NOW - 2000, { runId: "MINE", now: NOW }), false);
  // CONTROL: drop the extra block and the same document IS selected, so the
  // rejection above is the block count and not something else about it.
  assert.equal(sweepCandidate({ ...authored, blocks: TPL }, NOW - 2000, { runId: "MINE", now: NOW }), true);
});

test("a PUBLISHED document is never selected, stamped or not", () => {
  const published = { ...TITLED_LIVE[0], _draft: false, [STAMP_FIELD]: stamp({ run_id: "DEAD" }), _createdAt: at(STALE_DEBRIS_MS + 60_000) };
  assert.equal(sweepCandidate(published, 0, { runId: "MINE", now: NOW }), false);
  // CONTROL: the identical document as a draft IS selected.
  assert.equal(sweepCandidate({ ...published, _draft: true }, 0, { runId: "MINE", now: NOW }), true);
});

// ── THE SIX AS THEY STAND ON THE HOST TODAY ─────────────────────────────────
test("the six catalogued drafts are NOT selected by the new predicate either — they predate the stamp", () => {
  // Deliberate, and it is the reason task-d582be9d064f35dc's third criterion is a
  // LIST and not a delete. Nothing stamped them, so nothing can prove by rule
  // that they are harness debris rather than a paper somebody opened and left.
  // They are disposed of by hand, with authorisation, and the fix is forward-only.
  for (const d of LIVE) {
    assert.equal(harnessStamped(d), false, `${d._id} unexpectedly carries a stamp`);
    assert.equal(sweepCandidate(d, NOW - 2000, { runId: "MINE", now: NOW }), false, `${d._id} would be deleted by a future run`);
  }
});
