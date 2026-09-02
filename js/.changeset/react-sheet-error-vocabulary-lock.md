---
'@barkpark/react': patch
---

Sheets: the React sheet emitter's engine error vocabulary is now a CHECKED mirror instead of a silent fork. `ERROR_VALUES` in `src/blocks/sheet.ts` decides whether a cell renders red + bold, and it was hand-copied from `Barkpark.Plugins.Sheets.Engine.error_values/0` with nothing comparing the two — the only one of the five mirrors with no drift test, so a code added engine-side would have rendered as plain text here while every other surface marked it red. The list is now exported and locked by `tests/sheet-error-vocabulary.test.ts` to the same engine-generated fixture the web mirror consumes (`web/__tests__/fixtures/engine-errors.json`, itself asserted equal to the engine list by the Elixir parity suite), so neither side can move alone. No behaviour change: the two lists were already identical at the time of the fix.
