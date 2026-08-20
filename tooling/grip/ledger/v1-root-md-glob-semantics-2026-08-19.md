<!-- doc-tier: cold | canonical-for: rederive-root-md-glob-doc-gates-trigger | budget: 3000tok -->

# Re-derivation recipe — does `**/*.md` in doc-gates trigger on ROOT-level .md?

VERDICT: YES. `**/*.md` matches root-level files. Proven empirically on two
independent PRs whose ENTIRE changed file set was a single root-level .md,
both of which rendered the `Doc budgets + anchors` check (the doc-gates job).

## Step 1 — confirm the glob is the only .md trigger

    git show origin/main:.github/workflows/doc-gates.yml | sed -n '8,20p;160,172p'

Both `push.paths` and `pull_request.paths` start with `- "**/*.md"`; no
root-anchored `- "*.md"` line exists anywhere in the file.

## Step 2 — confirm root .md is inside the guard's SUBJECT SET

    git show origin/main:scripts/docs-anchors-check.sh | grep -n 'CLAUDE.md\|maxdepth 2\|canonical-for'

§1 reads root `CLAUDE.md` routing table; §-header/canonical-for scans use
`find . -maxdepth 2 \( -name 'CLAUDE.md' -o -name 'AGENTS.md' -o -name
'README.md' \)`. So CLAUDE.md/README.md breakage IS this guard's business.

## Step 3 — find root-md-only commits (full history, not the last 300)

    python3 - <<'PY'
    import re,subprocess
    out=subprocess.run(['git','log','origin/main','--format=@@%H','--name-only'],
                       capture_output=True,text=True).stdout
    cur=None;files=[]
    def flush():
        if cur and files and all(re.fullmatch(r'[A-Za-z0-9_.-]+\.md',f) for f in files):
            print(cur,files)
    for line in out.splitlines():
        if line.startswith('@@'): flush(); cur=line[2:]; files=[]
        elif line.strip(): files.append(line.strip())
    flush()
    PY

30 such commits exist across full history (CLAUDE.md x7, README.md x22,
one CLAUDE.md+README.md).

## Step 4 — read the check run on the PR head (the decisive read)

    gh api "repos/FRIKKern/barkpark/commits/7cb8559f8650849d2541d57df8c152ebbeeefae2/check-runs?per_page=100" \
      -q '.check_runs[] | "\(.name)\t\(.conclusion)"' | sort
    # PR #6687, file set == ["CLAUDE.md"] -> "Doc budgets + anchors  success"

    gh api "repos/FRIKKern/barkpark/commits/a7262373c453886d9069614dcae5be53adb39ebe/check-runs?per_page=100" \
      -q '.check_runs[] | "\(.name)\t\(.conclusion)"' | sort
    # PR #701, file set == ["README.md"] -> "Doc budgets + anchors  success"

Push-side confirmation on the merge commit:

    gh api "repos/FRIKKern/barkpark/actions/runs?head_sha=42406cd03b1122efd8f79f925dbb101b813ba239&per_page=100" \
      -q '.workflow_runs[] | "\(.name)\t\(.event)\t\(.conclusion)"'
    # doc-gates  push  cancelled   <- TRIGGERED (concurrency-cancelled != untriggered)

## Trap — why the naive search returns zero

    gh pr list --repo FRIKKern/barkpark --state all --limit 200 --json number,headRefOid,files

samples only the 200 MOST RECENT PRs (window #12030-#12570 on 2026-08-19).
Both specimens are #701 and #6687 — thousands of PRs outside the window.
A zero from that command is a WINDOWING ARTIFACT, not absence. Derive
candidates from `git log --name-only` over full history instead, then map
commit -> PR with `gh api repos/OWNER/REPO/commits/<sha>/pulls`.
