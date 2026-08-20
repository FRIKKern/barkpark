# Green baseline — create-barkpark-app + @barkpark/codegen (2026-08-18)

Re-derivation recipes for the `create-app-codegen-correctness-wave-2026-08-18` baseline gate.
All commands are run from the primary checkout; `js/` carried **no** uncommitted edits at the
time of the run, and `js/packages/*/src` + their test trees were byte-identical to `origin/main`
(local `main` was 3 commits behind, all three touching `templates/` + `.changeset/` only).

## 1. Tree provenance

    cd /Volumes/SATECHI/github/barkpark
    git status --porcelain js/                       # -> empty (no foreign uncommitted js edits)
    git rev-list --left-right --count origin/main...HEAD   # -> "3	0" (behind, never ahead)
    git diff --stat origin/main HEAD -- \
      js/packages/codegen/src js/packages/create-barkpark-app/src \
      js/packages/codegen/test js/packages/codegen/tests \
      js/packages/create-barkpark-app/tests           # -> empty: audited trees == origin/main

## 2. Suites (proven green)

    cd /Volumes/SATECHI/github/barkpark/js
    pnpm --filter @barkpark/codegen test        # 7 files / 66 tests passed
    pnpm --filter create-barkpark-app test      # 2 files / 21 tests passed

## 3. Collection — codegen collects BOTH `test/` and `tests/`

Neither `vitest.config.ts` sets `test.include`, so vitest's default glob picks up both dirs.

    cd js/packages/codegen && npx vitest list | awk -F' > ' '{print $1}' | sort | uniq -c
    # 8 test/cli-config.test.ts   5 test/cli-from.test.ts   25 test/generate.test.ts
    # 2 test/nameless-composite.test.ts
    # 20 tests/generate.test.ts   4 tests/schema-url.test.ts   2 tests/smoke.test.ts   => 66

## 4. Locale invariance (settles the localeCompare determinism worry)

    cd js/packages/codegen
    for L in C tr_TR.UTF-8 nb_NO.UTF-8 de_DE.UTF-8; do LC_ALL=$L LANG=$L npx vitest run; done
    # 66/66 under every locale; Node DOES adopt the locale
    #   (Intl.DateTimeFormat().resolvedOptions().locale -> tr-TR / nb-NO / de-DE)

Drift fixture `web/lib/barkpark.schema.json` carries 45 schemas, **zero** non-ASCII schema/field/
option names and no case-collision pairs -> no live divergence for the implicit-locale sorts.

## 5. CI drift gate, re-derived end to end (network-free)

Scratch script (outside the repo) calling `generateTypes` from `src`:

    import { generateTypes } from '<repo>/js/packages/codegen/src/generate.ts'
    const envelope = JSON.parse(readFileSync('<repo>/web/lib/barkpark.schema.json','utf8'))
    const out = await generateTypes(envelope, { dataset: 'production' })
    // compare against <repo>/web/lib/barkpark.types.ts
    # run with: js/packages/codegen/node_modules/.bin/jiti <script>   (no tsx in the workspace)

From cwd `js/` (the CI job's cwd) the output is **byte-identical** to the committed
`web/lib/barkpark.types.ts` (57603 bytes) -> the drift gate is genuinely green.

## 6. CWD-dependent formatting (new candidate)

`src/generate.ts:294` — `prettier.resolveConfig(process.cwd())`. The argument is treated as a
FILE path, so the search starts in the cwd's PARENT:

    cwd=js/                     -> searches repo root -> no config -> prettier defaults -> 57603 B (== committed)
    cwd=js/packages/codegen/    -> finds js/.prettierrc (semi:false) -> 56512 B (differs)

Same schema, same options, same locale, different bytes. Contradicts the function's own
"Deterministic: the same input always produces byte-identical output" docstring, and means the
committed artifact is formatted with prettier DEFAULTS, not "the repo's prettier config".
