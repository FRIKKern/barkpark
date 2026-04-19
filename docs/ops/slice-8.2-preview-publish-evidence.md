# Slice 8.2 — `@preview.0` npm Publish Evidence

- **Date:** 2026-04-19
- **Slice:** Phase 8 / Slice 8.2 — preview-tagged npm publish of the JS SDK
- **Branch:** `phase-8/slice-2-evidence-doc`
- **Main HEAD at branch point:** `3a8af194f567e8ab036231735e99be3f563426c5`
- **Run URL:** https://github.com/FRIKKern/barkpark/actions/runs/24625047707

## OUTCOME: SUCCESS

Slice 8.2 succeeded on npm. CI run `24625047707` published all 7 packages at
`1.0.0-preview.0` (5 real + 2 unexpected placeholders) with both `preview` and
`latest` dist-tags set.

- **5 real packages** (intended): `@barkpark/core`, `@barkpark/codegen`,
  `@barkpark/react`, `@barkpark/nextjs`, `create-barkpark-app`
- **2 placeholder packages** (unexpected — follow-up): `@barkpark/groq`,
  `@barkpark/nextjs-query` published at `0.0.0-placeholder`

End-to-end install transcript clean against the live registry.

## Recovery chain — 4 failed runs + 1 success

| Run ID      | Status  | Root cause                                        | Fix PR |
|-------------|---------|---------------------------------------------------|--------|
| 24624052160 | failure | pre-mode `--tag` conflict (tag already implicit)  | #19    |
| 24624290960 | failure | `NPM_TOKEN` missing bypass-2FA capability         | #20    |
| 24624477738 | failure | E422 provenance — repository field missing        | #20    |
| 24624540699 | failure | refire while token still mis-scoped               | #20    |
| **24625047707** | **success** | —                                         | —      |

Pull requests:
- **#18** — preview.0 bump (`main@7158e43`)
- **#19** — drop `--tag` in pre-mode publish (`main@49a1182`)
- **#20** — add `repository` field to all package.json for provenance
  (`main@3a8af194f567e8ab036231735e99be3f563426c5`)

## Per-package `npm view` output (verbatim)

```
=== @barkpark/core ===
1.0.0-preview.0
{ preview: '1.0.0-preview.0', latest: '1.0.0-preview.0' }
git+https://github.com/FRIKKern/barkpark.git

=== @barkpark/codegen ===
1.0.0-preview.0
{ preview: '1.0.0-preview.0', latest: '1.0.0-preview.0' }
git+https://github.com/FRIKKern/barkpark.git

=== @barkpark/react ===
1.0.0-preview.0
{ preview: '1.0.0-preview.0', latest: '1.0.0-preview.0' }
git+https://github.com/FRIKKern/barkpark.git

=== @barkpark/nextjs ===
1.0.0-preview.0
{ preview: '1.0.0-preview.0', latest: '1.0.0-preview.0' }
git+https://github.com/FRIKKern/barkpark.git

=== create-barkpark-app ===
1.0.0-preview.0
{ preview: '1.0.0-preview.0', latest: '1.0.0-preview.0' }
git+https://github.com/FRIKKern/barkpark.git
```

All 5 real packages report `version=1.0.0-preview.0`, both `preview` and
`latest` dist-tags pointing at that version, and the `repository.url` field
set to the canonical `FRIKKern/barkpark` remote (required for npm provenance
attestation).

## Placeholder packages — informational

```
=== @barkpark/groq ===
0.0.0-placeholder
{ preview: '0.0.0-placeholder', latest: '0.0.0-placeholder' }

=== @barkpark/nextjs-query ===
0.0.0-placeholder
{ preview: '0.0.0-placeholder', latest: '0.0.0-placeholder' }
```

These two packages were not intended to ship in slice 8.2. The `0.0.0-placeholder`
versions landed on the registry because release tooling published every
workspace package regardless of intent.

**Recommended follow-up (separate slice):** either set `"private": true` on
both workspace manifests to prevent future publishes, or `npm deprecate` the
orphan placeholder versions so consumers see a warning. **Do NOT** `npm unpublish` — that breaks future re-use of the name under npm's 72-hour policy and is explicitly out of scope.

## Install transcript excerpts

Clean-room verification from an empty project:

```
$ mktemp -d /tmp/bp-install-XXXXXX
/tmp/bp-install-LA6TMR

$ npm init -y && npm pkg set type=module
$ npm install @barkpark/nextjs@preview
added 25 packages, and audited 26 packages in 9s
found 0 vulnerabilities

$ ls node_modules/@barkpark
core  nextjs

$ cat node_modules/@barkpark/nextjs/package.json | jq '{name, version, dependencies, peerDependencies}'
{
  "name": "@barkpark/nextjs",
  "version": "1.0.0-preview.0",
  "dependencies": {
    "@barkpark/core": "^1.0.0-preview.0"
  },
  "peerDependencies": {
    "next": ">=15 <17",
    "react": ">=19",
    "react-dom": ">=19",
    "zod": "^3.23.0"
  }
}

$ npm install @barkpark/core@preview
up to date, audited 26 packages in 977ms
found 0 vulnerabilities

$ cat node_modules/@barkpark/core/package.json | jq '{name, version}'
{
  "name": "@barkpark/core",
  "version": "1.0.0-preview.0"
}
```

`@barkpark/nextjs@preview` transitively pulls `@barkpark/core@^1.0.0-preview.0`
as expected. `peerDependencies` resolve to Next 15+, React 19+, and Zod 3.23+.
No vulnerabilities reported.

## PR chain

| PR  | Title                                              | main SHA at merge |
|-----|----------------------------------------------------|-------------------|
| #18 | chore(release): Phase 8 slice 8.2 — @preview.0 npm publish | `7158e43` |
| #19 | fix(release): drop --tag in pre-mode publish (pre.json auto-applies tag) | `49a1182` |
| #20 | fix(release): add repository field to package.json for provenance (E422) | `3a8af194f567e8ab036231735e99be3f563426c5` |

## Constraint hygiene

- `NPM_TOKEN` is stored only as a GitHub Actions repository secret via
  `gh secret set NPM_TOKEN`; it is never committed or echoed in workflows.
- The token is a **granular access token** with `bypass-2FA` enabled on the
  token itself — not on the npm account. Publishing packages that require 2FA
  works in CI without weakening the account's interactive-login protections.
- Provenance attestation requires the `repository` field in every
  published `package.json` (E422 was the symptom until PR #20 added it).

## Open follow-ups

- **(a) Placeholder cleanup** — mark `@barkpark/groq` and
  `@barkpark/nextjs-query` as `"private": true` in their workspace
  manifests, or `npm deprecate` the published `0.0.0-placeholder` versions.
  Do NOT `npm unpublish`.
- **(b) `@barkpark/core` lint debt** — 3 unused-variable lint errors
  deferred from the slice 8.2 main PR. Clear before `1.0.0` stable cut.
- **(c) Hetzner API token rotation** — still pending under task #4.

## GATE checklist

- [x] Real packages live on npm registry (`1.0.0-preview.0`)
- [x] `preview` dist-tag set on all 5 real packages
- [x] `repository.url` field present (provenance E422 resolved)
- [x] Install transcript clean (`@barkpark/nextjs@preview` + transitive `@barkpark/core`)
- [ ] Placeholder cleanup (follow-up a)
- [ ] `@barkpark/core` lint errors (follow-up b)
