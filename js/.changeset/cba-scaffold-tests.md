---
'create-barkpark-app': patch
---

Internal: wire up vitest for the scaffolder and add a unit suite for its pure helpers (`toPackageName`, `renderTemplate`, `normalizeProjectName`, `detectPackageManager`) — the package previously had zero tests. Pins the npm-name slugification rules, template `{{var}}` substitution (including the `hasOwnProperty` guard against leaking inherited props and the unknown-placeholder passthrough), project-name basename normalization, and package-manager detection from `npm_config_user_agent`/`npm_execpath`. No runtime change.
