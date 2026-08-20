---
'create-barkpark-app': patch
---

Never scaffold a `package.json` named `node_modules` or `favicon.ico`. `_` and `.` are legal npm name characters, so both names passed through `toPackageName` byte-for-byte — and both are hard-invalid (`validForOldPackages: false`), which makes yarn classic exit 1 with `error package.json: Name is blacklisted` on the install step the CLI runs seconds later. Both now scaffold as `<name>-app`. The emitted name is also clamped to npm's 214-character ceiling (hardening — over it is only a warning), with a trailing `-`/`.` left by the cut re-trimmed. Plausible names npm merely warns about (`stream`, `http`) or accepts (`test`) are unchanged.
