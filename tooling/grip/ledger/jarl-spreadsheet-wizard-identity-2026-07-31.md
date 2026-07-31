# jarl-historiene — Spreadsheet Wizard / nextgen-vscode / SVGLoop identity, re-derived from the remotes

Run 2026-07-31 with `gh` authenticated as `FRIKKern` (scopes `gist, read:org, repo,
workflow` — the `repo` scope is what makes the PRIVATE repos below resolvable; a
token without it will 404 on `nextgen-vscode`, `svgloop-svelte` and
`svg-animate-check` and produce a false "does not exist"). Every line is a
re-derivation recipe, not a conclusion.

## 1. Spreadsheet Wizard EXISTS — the 2022 Sanity plugin, co-authored

    gh api repos/Guerrilla-Interactive/spreadsheet-wizard \
      --jq '{html_url,created_at,pushed_at,private}'
    # -> {"created_at":"2022-04-15T23:23:46Z","html_url":"https://github.com/Guerrilla-Interactive/spreadsheet-wizard",
    #     "private":false,"pushed_at":"2022-06-12T20:02:04Z"}

    gh api repos/Guerrilla-Interactive/spreadsheet-wizard/commits --paginate \
      --jq '.[]|[.commit.author.date,.commit.author.name]|@tsv' | sort | sed -n '1p;$p'
    # -> 2022-04-15T23:27:50Z  Frikk Jarl      (6c0808eb "sanity pugin init w spreadsheet-wizard")
    # -> 2022-06-12T20:01:45Z  suman chapai    (0daa9ae8 "config.dist.json fix")
    # 41 commits: 36 suman chapai <sumanchapai@gmail.com>, 5 Frikk Jarl <Frikk@jarl.email>

    npm view sanity-plugin-spreadsheet-wizard versions author
    # -> versions = [ '0.0.92', '0.0.93', '0.0.96' ]
    # -> author = 'Frikk Jarl & Suman Chapai - Frikk@guerrilla.no'

Corrections to wave G's dates: the repo's FIRST commit is **2022-04-15**, not
04-17 (04-17 is the first npm publish, `0.0.5` at 17:28:16Z). Last commit and
last publish are both **2022-06-12**. npm `versions` lists only 3 live versions,
but `time` records 7 publishes (0.0.5, 0.0.6, 0.0.65, 0.0.66, 0.0.92, 0.0.93,
0.0.96) — 0.0.5–0.0.66 were unpublished. Quote "seven releases in eight weeks"
from `time`, or "v0.0.96 latest" from `dist-tags`, never "96 versions".

Kilde stamps usable verbatim:
* https://github.com/Guerrilla-Interactive/spreadsheet-wizard (public)
* https://www.npmjs.com/package/sanity-plugin-spreadsheet-wizard

## 2. The rival identity is REFUTED as an identity (it is the sequel)

Barkpark has no "Spreadsheet Wizard". Its spreadsheet surface is named **Sheets**:

    bp search query "spreadsheet wizard"   # 50 hits, zero name a Barkpark plugin by that name
    find barkpark -maxdepth 4 -iname '*sheet*' -not -path '*/node_modules/*'
    # -> web/lib/sheets.ts, web/components/sheet-grid.tsx, internal/pdrender/sheet_test.go, …

So the page tells a 2022 -> 2026 arc (Sanity plugin -> Barkpark Sheets), not a
single artifact. Do not caption the 2022 screenshots "Barkpark".

## 3. nextgen-vscode EXISTS — under the USER, not the org

Wave G's ancestor node upgrades from testimony to artifact, but the path the
brief guessed is wrong:

    gh repo view Guerrilla-Interactive/nextgen-vscode
    # -> GraphQL: Could not resolve to a Repository with the name '…' (repository)

    gh api 'search/repositories?q=nextgen+user:FRIKKern' --jq '.items[].full_name'
    # -> FRIKKern/nextgen-vscode           <- HERE (private)

    gh api repos/FRIKKern/nextgen-vscode/contents --jq '.[]|.name' | grep nextgen
    # -> ng-test-example.nextgen
    gh api repos/FRIKKern/nextgen-vscode/contents/ng-test-example.nextgen --jq .content \
      | base64 -d | head -1
    # -> COMMAND "Insert Page Type with Block Editor" DESCRIPTION "…" LAST_UPDATED
    #    "29-09-2025-13-48-08" DOMAIN "sanity-template-nextjs-clean" … VARIABLES

10 commits, 2025-10-05 (`c7dcdb6b chore: initial commit`) -> 2026-05-29. It is
**private**: a kilde stamp pointing at it is a dead link for a stranger. Quote
the grammar line as an inline excerpt with the repo named, or make the repo
public first.

## 4. svgloop-svelte is an EMPTY SHELL — and the public "SVGLoop" is someone else's

    gh api repos/Guerrilla-Interactive/svgloop-svelte/commits --jq '.[]|[.commit.author.date,.commit.author.name,.sha[0:8],.commit.message]|@tsv'
    # -> 2024-07-15T20:57:35Z  FRIKKern  539af2b6  Initial commit      (ONE commit, private)

    gh api "repos/Guerrilla-Interactive/svgloop-svelte/git/trees/539af2b6?recursive=1" \
      --jq '.tree[].path' | grep -ci svgloop
    # -> 0

40 blobs, all `create-svelte` **demo-app** template (`sverdle/`, `Counter.svelte`,
package name `sveltekit-2`). Nothing named svgloop; no SVGLoop code exists here.

    gh api 'search/repositories?q=svgloop' --jq '.items[]|[.full_name,.owner.login]|@tsv'
    # -> strangersinsist/SVGLoop   zyh <zhuyue7577@outlook.com>   <- NOT Frikk's
    # -> Guerrilla-Interactive/svgloop-svelte

The public github.com/strangersinsist/SVGLoop ("Ralph-style SVG generation loop
with Claude Code, Codex, and multi-agent visual review", 2026-07) is a **name
collision by a different author** — every commit is `zyh`. Linking it as kilde
would credit a stranger.

Best remaining candidate for the real artifact, unconfirmed by name:

    gh api repos/Guerrilla-Interactive/svg-animate-check --jq '{created_at,pushed_at,private}'
    # -> 2024-05-22T11:18:36Z -> 2025-05-06T12:13:12Z, private
    # 118 commits, 117 "Frikk Jarl" + 1 "FRIKKern"; Next.js app, @dnd-kit, exportSVG.ts
    # README is the untouched create-next-app boilerplate — it does NOT say "SVGLoop"

The local clone `/Users/frikkjarl/Documents/GitHub/svg-animate-check` is STALE
(HEAD `e414f58 Better darkmode`, 2024-06-18) — fetch before reading it as truth.
Naming svg-animate-check "SVGLoop" needs the author's own confirmation; on the
evidence alone it is an inference, not a fact.
