---
'@barkpark/nextjs': patch
---

Bundle budget: `.size-limit.json` now caps every entry tsup builds, not five of nine.

`tsup.config.ts` declares nine entries (`index`, `server`, `client`, `actions`, `webhook`, `draft-mode`, `revalidate`, `preload`, `csp`) and every one of them except `index` is a published `exports` subpath. The size file named five: `server`, `client`, `revalidate`, `preload`, `csp`. The root export and the `./actions`, `./webhook` and `./draft-mode` subpaths — including the one client bundle a consumer of `useOptimisticDocument` actually ships — were shipped under no cap at all.

MEASURED on this head, not argued: appending a 4,000-element string literal to `src/actions/index.ts` grew `dist/actions.mjs` from 6,610 B to 241,556 B, and `pnpm --filter @barkpark/nextjs size` still exited 0, printing the same five unchanged lines. With the four entries added the identical mutation exits 1 with `./actions … Package size limit has exceeded by 4.05 kB`, and an innocuous comment on the same file leaves `dist/actions.mjs` byte-identical at 6,610 B and the gate green.

Caps are the measured size plus headroom, in the style of the existing entries: `index` 298 B → 500 B, `actions` 1.5 kB → 2 KB, `webhook` 1.4 kB → 2 KB, `draft-mode` 918 B → 1.25 KB. No emitted byte changes; this is a guard-coverage change only.
