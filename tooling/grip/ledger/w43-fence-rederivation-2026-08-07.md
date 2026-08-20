# Recipe — re-derive the wave-43 console merge fence

Baseline: `origin/main` = `dad66869e` (2026-08-07T08:53Z). Re-run all of it after any fetch.

## 0. Refresh

    git -C /Volumes/SATECHI/github/barkpark fetch origin --quiet && git rev-parse origin/main

## 1. Every OPEN PR that touches a console file (do NOT trust a hand-kept list)

    gh pr list --state open --limit 100 --json number,title,files,mergeable,updatedAt \
      -q '.[] | select(.files[].path | test("cloud/priv/static/(app\\.js|__app\\.test\\.mjs|__preview__/(scenarios|smoke)\\.mjs|__binding_census\\.mjs)")) | "#\(.number) \(.mergeable) \(.updatedAt) \(.title[0:70])"' | sort -u

D477's fence named 9955/10005/10006/6028. This query also returns **#10085**
(`__binding_census.mjs`) — a hand-kept list drops it.

## 2. Net hunk ranges per PR, in that PR's OWN merge-base coordinates

    for p in 10005 9955 10006 10085 10129; do
      h=$(gh pr view $p --json headRefOid -q .headRefOid)
      mb=$(git merge-base origin/main $h)
      echo "===== #$p base=$mb behind=$(git rev-list --count $mb..origin/main)"
      git diff -U0 $mb $h -- cloud/priv/static cloud/lib | grep -E '^(diff --git|@@)'
    done

`gh pr diff --patch` emits ONE patch PER COMMIT, so the same file appears twice
and the second block's line numbers are post-first-commit. Always use
`git diff <merge-base> <head>` for a fence. Note `zsh` eats `$mb:cloud/...` as a
history modifier — write `${mb}:cloud/...`.

## 3. Map a base line to a main line (a PR 28 commits behind does NOT share coords)

    mb=$(git merge-base origin/main <head>)
    git show ${mb}:cloud/priv/static/app.js | grep -nE 'function (renderTeamMenu|memberRowHtml)\b'
    git show origin/main:cloud/priv/static/app.js | grep -nE 'function (renderTeamMenu|memberRowHtml)\b'

## 4. EOF-tail ownership (an append is only an append if the hunk starts at the last line)

    git show ${mb}:cloud/priv/static/__app.test.mjs | wc -l    # must equal the hunk's -START

#10005: base file is 15614 lines, hunk `@@ -15614,0 +15635,168 @@` ⇒ pure EOF append.

## 5. Object-tail lines on main (SCENARIOS / EXPECTATIONS)

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -nE '^export const SCENARIOS|^};'
    git show origin/main:cloud/priv/static/__preview__/smoke.mjs     | grep -nE '^const EXPECTATIONS|^};'

## 6. Which keys a PR claims (name the KEY, never the line — lines drift)

    git diff -U6 $mb $h -- cloud/priv/static/__preview__/scenarios.mjs | grep -E '^\+\s{2}"[a-z0-9-]+":'

## 7. Conflicting PRs — WHICH files

    git merge-tree --write-tree origin/main <head> | grep CONFLICT

## 8. me() fixture key census (balanced-paren, because a `[^)]*` regex undercounts)

    python3 - <<'PY'
    import re,subprocess
    s=subprocess.run(['git','show','origin/main:cloud/priv/static/__preview__/scenarios.mjs'],
                     capture_output=True,text=True).stdout
    calls=[]
    for m in re.finditer(r'\bme\(', s):
        i=m.end(); d=1; j=i
        while d>0 and j<len(s):
            d += (s[j]=='(') - (s[j]==')'); j+=1
        calls.append(s[i:j-1])
    from collections import Counter
    print(len(calls), Counter(re.findall(r'"(owner|admin|member)"\s*\Z', c.strip())[0]
          if re.findall(r'"(owner|admin|member)"\s*\Z', c.strip()) else '<none>' for c in calls))
    PY
