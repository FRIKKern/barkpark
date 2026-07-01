---
'create-barkpark-app': patch
---

Print a clean one-line message for expected failures instead of a full V8 stack trace. The `ensureTargetEmpty()` check runs outside `main()`'s try/catch, so an expected error like `Target directory "…" is not empty.` used to reject the top-level promise and get dumped as a multi-line stack — the most common first-run scaffolder mistake. The top-level `.catch` now prints `(err as Error).message` by default and only emits the stack when `DEBUG` is set, matching create-next-app / create-vite behavior.
