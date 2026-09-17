---
---

Empty changeset: turbo task-input configuration only, no published package changes.

Three sibling stale-green shapes reported by #14338 and left unpatched:

1. `@barkpark/react`'s `paper-surface-asset.test.ts` reads
   `api/assets/paper-surface/paper-surface.css` — OUTSIDE the `js/` turbo root.
   Turbo 2.9.18 accepts `$TURBO_ROOT$/../api/...` and hashes it (measured), so
   the drift guard now executes on the api-side edit it exists to catch. The
   same glob is added to `build` so the tsup copy re-syncs instead of reddening.
2. Built-output reads absent from `test` inputs: `@barkpark/astro-parity` reads
   `dist/index.html`, `create-barkpark-app` shells out to `dist/index.js`, and
   `@barkpark/react` asserts `dist/paper-surface.css`. All three gained
   `dist/**` in `inputs` and their OWN `build` in `dependsOn` (they only had
   `^build`, which is dependencies' builds, never their own).
3. `@barkpark/astro-parity`'s `build` did not declare `astro.config.mjs`.

Every `inputs` override RESTATES the root globs verbatim — an override REPLACES
the array, so an unrestated glob would silently narrow.
