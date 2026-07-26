// PURE BARREL (charter D49). The 969-line renderer that lived here split into
// per-family modules mirroring @barkpark/react's DISPATCH:
//
//   register.ts          BlockCtx/Render/BlockRegister, REGISTERS, spec, bodyText
//   registry.tsx         BLOCK_RENDERERS (per-family spreads) + renderBlockNative
//   blocks/<family>.tsx  the emitter maps (core-prose, core-media, core-container,
//                        core-doc, core-code, dataviz, forms, math, sheet, table,
//                        taskboard — stubs included, so adding a type touches only
//                        its family file)
//
// This barrel exists so the import path stays zero-diff for every consumer
// (ChatSessionScreen, PaperReaderScreen, and the test suites). Add nothing
// else here: new renderers go in their family module, new register chrome in
// register.ts.
export * from './register'
export * from './registry'
