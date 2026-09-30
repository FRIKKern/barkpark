---
'create-barkpark-app': patch
---

Fresh scaffolds no longer ship a high-severity `npm audit` finding. The starters' `package.json` overrides postcss to `^8.5.28` for npm/bun (`overrides`), pnpm (`pnpm.overrides`) and yarn (`resolutions`), with the direct devDependency on the same range, instead of bumping Next to 16. `npm audit --audit-level=high` on a fresh scaffold of either template now reports 0 vulnerabilities.
