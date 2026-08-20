# Re-derivation recipe — toPackageName reserved-name / length gaps (verifier: npm-name-validity)

Wave: create-app-codegen-correctness-wave-2026-08-18. Verdict: reserved names are npm
**ERRORS** (validate-npm-package-name) and a **yarn-classic install HARD FAIL**; >214 chars is a
**WARNING only** everywhere tested. `toPackageName` passes all three through unchanged.

Node v22.22.0 · npm 11.18.0 · pnpm 9.12.0 · yarn 1.22.22 · bun 1.3.14 · validate-npm-package-name 7.0.2

## 1. Current toPackageName output + npm validation (passthrough proof)

```sh
cd /Volumes/SATECHI/github/barkpark && node -e '
const toPackageName = n => (String(n).toLowerCase()
  .replace(/[^a-z0-9-_.]+/g,"-").replace(/^[._]+/,"")
  .replace(/-+/g,"-").replace(/^-+|-+$/g,"")) || "barkpark-site";
const {createRequire}=require("module");
const v=createRequire("/Users/pelle/.nvm/versions/node/v22.22.0/lib/node_modules/npm/x.js")("validate-npm-package-name");
for (const n of ["node_modules","favicon.ico","a".repeat(300)]) {
  const o = toPackageName(n);
  console.log(n.slice(0,15), "len",n.length, "-> unchanged:", o===n, JSON.stringify(v(o)));
}'
```

Expected: `node_modules` / `favicon.ico` → `errors:["… is not a valid package name"]`,
`validForOldPackages:false`. 300×`a` → `warnings:["name can no longer contain more than 214
characters"]`, `validForOldPackages:true`. All three `unchanged: true`.

Source of truth for the function:
`git show origin/main:js/packages/create-barkpark-app/src/scaffold.ts | sed -n '105,118p'`

## 2. Does a scaffolded project still install? (per package manager)

Fixture: `{"name":"<N>","version":"0.1.0","private":true,"dependencies":{"is-number":"^7.0.0"}}`

```sh
D=$(mktemp -d); cd "$D"
node -e 'require("fs").writeFileSync("package.json",JSON.stringify({name:"node_modules",version:"0.1.0",private:true,dependencies:{"is-number":"^7.0.0"}}))'
npm  install --dry-run --no-audit --no-fund; echo "npm=$?"
pnpm install --lockfile-only;               echo "pnpm=$?"
bun  install --dry-run;                     echo "bun=$?"
yarn install --mode=update-lockfile;        echo "yarn=$?"
```

Observed: npm=0, pnpm=0, bun=0 — **yarn=1** with
`error package.json: Name is blacklisted`. Same for `favicon.ico`.
300-char name: yarn=0 (`success Saved lockfile.`) — soft everywhere.

Reachability: `yarn` is a first-class branch of
`git show origin/main:js/packages/create-barkpark-app/src/pm.ts` (`ua.startsWith('yarn')` →
`installCommand: 'yarn'`), so `yarn create barkpark-app node_modules` fails its own install step.

## 3. npm publish (secondary; both templates are `private: true`)

```sh
D=$(mktemp -d); cd "$D"
node -e 'require("fs").writeFileSync("package.json",JSON.stringify({name:"node_modules",version:"0.1.0",private:true}))'
npm publish --dry-run; echo "exit=$?"
```

Observed `npm error Invalid name: "node_modules"`, exit 1 — the name check fires **before** the
`private` check. 300-char name: exit 0, only an `npm notice name: aaa…`.

## 4. Core-module names are warnings, not errors

`stream`, `http`, `fs`, `path`, `util`, `events`, `crypto` → `warnings:["… is a core module
name"]`, `validForOldPackages:true`. `test` is fully valid. Blacklist is exactly two names.

## 5. Baseline greenness (so a red-first test means something)

```sh
git diff --stat origin/main -- js/packages/create-barkpark-app/src js/packages/create-barkpark-app/tests   # empty
cd js/packages/create-barkpark-app && npx vitest run
```
Observed: `Test Files 2 passed (2) / Tests 21 passed (21)`, src+tests byte-identical to origin/main.
