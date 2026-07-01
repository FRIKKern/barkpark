---
'create-barkpark-app': patch
---

Sanitize the scaffolded `package.json` `"name"`. Both starter templates hardcoded `"name": "{{projectName}}"` and the project name was substituted verbatim, so a target dir like `My App` produced the invalid npm name `My App`, and a name containing a double-quote produced structurally broken JSON that broke `npm install` on the fresh project. A new `packageName` template var runs the project name through `toPackageName()` (lowercase, non-`[a-z0-9-_.]` runs → `-`, no leading `.`/`_`, collapsed dashes, `barkpark-site` fallback). Also fixed the normalization split-brain: the `--yes` default and the explicit-target interactive branch now route through the same `normalizeProjectName()` (basename + trim) that the interactive prompt path already applied, so all three sources behave identically.
