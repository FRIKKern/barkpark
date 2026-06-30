---
'create-barkpark-app': patch
---

Scaffolded projects can now actually run `codegen`. The website + blog starters declared a `"codegen": "barkpark codegen"` script but (1) never listed `@barkpark/codegen` — which provides the `barkpark` binary — in devDependencies, so the command was `barkpark: not found`, and (2) invoked the non-existent `codegen` subcommand (the CLI exposes `generate`). Added `@barkpark/codegen` to both templates' devDependencies and fixed the script to `barkpark generate` (matching each template's own README, which already said "runs barkpark generate"). The blog starter's seed copy referencing `barkpark codegen` was corrected too.
