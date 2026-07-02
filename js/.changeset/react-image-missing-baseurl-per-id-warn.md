---
'@barkpark/react': patch
---

`BarkparkImage`: fix the missing-baseUrl diagnostics. The dev warning for an asset with no `.url` and no `baseUrl` used to be a module-level one-shot — the first broken image anywhere silenced the warning for every subsequent distinct broken asset in a long-lived Next dev/SSR process, and the message named no asset. It now de-dupes per asset id and names the id (`asset '<id>' has no .url and no baseUrl was provided; skipping render.`), so a blank image is debuggable. Also corrects the `onMissingBaseUrl` JSDoc: it fires on each render hitting that branch, not once. No render behavior changes.
