# Re-derivation recipe — guard #21 (scaffy anchor-drift) FULL anchor-target census vs doc-gates paths filter

Verifier: cgsi wave V1 [scaffy-anchor-full-extraction] · 2026-08-19 · base origin/main

VERDICT: SAFE, on a COMPLETE extraction (not a sample). 40 distinct `IN "…"` anchor
targets across 22 scaffy/commands/*.scaffy; 38 non-token; ZERO outside the 69-glob
pull_request filter. The surveyor's loose end (gen-showcase-content.mjs) is an
ASSERT CMD, not an anchor, and the file EXISTS — the gate is green on main.

## 1. Run the gate itself (the local `cc` alias shadows clang; CC must be set)

    cd /Volumes/SATECHI/github/barkpark
    CC=/usr/bin/clang go run ./cmd/barkpark scaffy validate --repo . scaffy/commands/; echo "rc=$?"
    # {"anchors_ok":50,"anchors_skipped_token":17,"files":22,"findings":[],"ok":true,"repo":"."}
    # rc=0

Note: the assignment's `scripts/scaffy-anchor-drift-check.sh` DOES NOT EXIST. The
guard is an inline `run:` at .github/workflows/doc-gates.yml:613-614.

## 2. Extract every anchored target path

    for f in $(git ls-tree -r --name-only origin/main scaffy/commands/); do \
      git show origin/main:$f; done | grep -E '^IN "' | sed 's/^IN "//; s/"$//' | sort -u

40 lines. Token-bearing (2): `{{.TargetFile}}`, `api/lib/barkpark/plugins/{{.plugin}}.ex`.

Extension histogram of the 38 non-token targets:
10 .ex · 6 .exs · 7 .ts · 5 .go · 3 .tsx · 3 .md · 1 .heex · 1 .js · 1 .mjs · 1 .sh

## 3. Glob-coverage diff (doc-gates.yml pull_request paths, 69 globs)

    git show origin/main:.github/workflows/doc-gates.yml \
      | sed -n '/^  pull_request:/,/^permissions:/p' | grep -E '^\s+- "' | nl

- .ex/.exs/.go/.ts/.tsx/.md → `**/*.<ext>` (globs 1-6). 34 of 38.
- api/lib/barkpark_web/layouts/root.html.heex → glob 16 (LITERAL) AND glob 50
  (`api/lib/barkpark_web/**/*.heex`). Double-covered.
- cloud/priv/static/app.js → glob 68 (literal). cloud/priv/static/__app.test.mjs → glob 69.
- scripts/pd-parity-completeness.sh → glob 65.
- The .scaffy corpus itself → glob 67 `scaffy/commands/**`; the validator source
  (internal/scaffy/**, cmd/barkpark/**) → globs 4/55/56.

UN-GLOBBED COUNT: 0.

## 4. The `**/*.md` root-level question (wave-flagged as material-unknown) — RESOLVED

`**/*.md` DOES match root-level files in a GitHub Actions paths filter. Proven by a
live single-file PR, not by recalling minimatch semantics:

    gh pr view 6687 --json files -q '.files[].path'      # -> CLAUDE.md   (root, only file)
    gh pr checks 6687 | grep 'Doc budgets'               # -> Doc budgets + anchors  pass  54s
    b=$(gh pr view 6687 --json baseRefOid -q .baseRefOid)
    git show $b:.github/workflows/doc-gates.yml | sed -n '/^  pull_request:/,/^permissions:/p' \
      | grep -E '^\s+- "' | grep -i 'md\|CLAUDE'          # -> only "**/*.md"; no literal CLAUDE.md

Second instance: PR 1156, files = CLAUDE.md only, Doc budgets + anchors pass 18s.
This retires the wave's "if `**/*.md` misses root files that outranks every Ring 2
finding" branch — it does not miss them.

## 5. The gen-showcase-content.mjs loose end

    git show origin/main:scaffy/commands/add-block-type.scaffy | grep -n gen-showcase-content
    # 753:ASSERT CMD "cd js/packages/create-barkpark-app && node scripts/gen-showcase-content.mjs"
    git ls-tree -r --name-only origin/main | grep gen-showcase-content
    # js/packages/create-barkpark-app/scripts/gen-showcase-content.mjs

It is an ASSERT CMD (a post-apply verification command), never an `IN` anchor, so
RepoCheck never resolves it. The path is relative to the `cd` target, not the repo
root — the surveyor resolved it against the root and read a phantom absence. The
file exists; the gate is not red.

## 6. Honest caveat that is NOT a gap

`{{.TargetFile}}` (add-canonical-marker, ensure-import) can name ANY repo file,
including extensions with no glob (.py/.css/.json). It is not a coverage hole
because RepoCheck SKIPS token-bearing anchors (anchors_skipped_token=17) — the
un-globbable case is exactly the structurally-uncheckable case. There is no PR
shape where the gate would have caught a drift but the filter suppressed the run.
The residual risk is the pre-existing "17 anchors never verified" one, which the
gate reports honestly rather than passing vacuously.
