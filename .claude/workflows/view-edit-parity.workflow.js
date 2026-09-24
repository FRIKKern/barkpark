// RETIRED (task-cc09124c3ad48942). This file is a pointer, not an audit.
//
// It used to be an LLM-vote static audit: agents read render.ex inline-style
// emitters and root.html.heex rules, guessed View/Edit divergences and voted
// on them. That premise went stale — the emitters moved to render/walk.ex,
// article headings are class-styled, and the Edit CSS moved to
// api/priv/static/assets/bp-paper-editor-shell.css — and a vote is not a
// measurement, so it could never serve as a zero-diff gate.
//
// Its replacement MEASURES computed style in Chromium, on the reader, the
// canvas and the public /papers editor:
//
//   cd api/assets/paper-editor && npm run test:view-edit-parity
//
// (src/__view_edit_parity_matrix.mjs; known divergences with reasons in
// src/view-edit-parity.known.json). The stub stays so the skill registry keeps
// pointing anyone who reaches for "view-edit-parity" at the instrument.

export const meta = {
  name: 'view-edit-parity',
  description: 'RETIRED, do not launch. The View↔Edit parity audit is now a measurement: run `npm run test:view-edit-parity` in api/assets/paper-editor (src/__view_edit_parity_matrix.mjs).',
  whenToUse: 'Never launch this workflow; it only returns a pointer. To check View↔Edit parity after touching the paper reader or editor styles, run `cd api/assets/paper-editor && npm run test:view-edit-parity` (needs Chromium and a compiled MIX_ENV=test api tree).',
  phases: [
    { title: 'Retired', detail: 'returns the pointer to npm run test:view-edit-parity' },
  ],
};

const POINTER = 'cd api/assets/paper-editor && npm run test:view-edit-parity';

phase('Retired');
log(`view-edit-parity is retired. Run instead: ${POINTER}`);

return { retired: true, run: POINTER };
