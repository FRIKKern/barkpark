---
'@barkpark/react': patch
---

Sheets: `#NAME?` cells now render red + bold through `@barkpark/react`, like every other surface. `ERROR_VALUES` in `src/blocks/sheet.ts` is the React emitter's mirror of `Barkpark.Plugins.Sheets.Engine.error_values/0`, and it still held seven codes after the engine gained an eighth — so a `#NAME?` cell came out as plain black text while the server, Studio, the Go TUI and mobile all painted it as an error. The drift guard in `tests/sheet-error-vocabulary.test.ts` had caught it and reported red; the red simply could not block a merge. The list now matches the engine fixture, and the comment above it records what actually pins the set and that the drift really happened.
