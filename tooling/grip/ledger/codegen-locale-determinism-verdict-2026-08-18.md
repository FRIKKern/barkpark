# Re-derivation recipe — codegen sort determinism + create-app exit-0 swallows (2026-08-18)

Wave: create-app-codegen-correctness-wave-2026-08-18 · lane: determinism-build-or-file
All commands run from the repo root. Baseline: `origin/main` @ 68b0b704287f8a9b374a6634a070e6a2618cb7a5.

## 1. The two comparator regimes DO diverge (locale-collation vs code-unit)

    node -e 'const n=["apple","Banana"];console.log([...n].sort((a,b)=>a.localeCompare(b)).join(","),"|",[...n].sort((a,b)=>a<b?-1:a>b?1:0).join(","))'
    # apple,Banana | Banana,apple

And they diverge on the REAL committed fixture (2 of 81 sorted name lists):
`rune|runRuleset` vs `runRuleset|rune`; `contributors|contributorStatement` vs `contributorStatement|contributors`.

    git show origin/main:web/lib/barkpark.schema.json > /tmp/fx.json
    node -e 'const s=JSON.parse(require("fs").readFileSync("/tmp/fx.json","utf8")).schemas;const n=s.map(x=>x.name);console.log([...n].sort((a,b)=>a.localeCompare(b)).join()===[...n].sort().join())'
    # false

## 2. The drift gate is GREEN and locale-env-INSENSITIVE today

    cd js
    for L in en_US.UTF-8 sv_SE.UTF-8 tr_TR.UTF-8 C POSIX; do
      LC_ALL=$L LANG=$L node packages/codegen/dist/cli.mjs generate \
        --from ../web/lib/barkpark.schema.json --dataset production --output /tmp/types.$L.ts
    done
    md5 /tmp/types.*.ts   # all 6f33e5d1165dab07f4c6f869bb4f8bc8
    git show origin/main:web/lib/barkpark.types.ts | md5   # same hash

Explicit-locale probe over all 81 lists (en-US, sv, da, tr, de, fr, en-US-u-kf-upper): 0 divergent pairs.

## 3. Cost of switching to a code-unit comparator = a regen OUTSIDE the fence

Emulate a no-Intl node (localeCompare degenerates to code-unit) and regen:

    printf 'String.prototype.localeCompare=function(t){const a=String(this),b=String(t);return a<b?-1:a>b?1:0}\n' > /tmp/nointl.mjs
    cd js && node --import /tmp/nointl.mjs packages/codegen/dist/cli.mjs generate \
      --from ../web/lib/barkpark.schema.json --dataset production --output /tmp/types.nointl.ts
    git show origin/main:web/lib/barkpark.types.ts > /tmp/types.committed.ts
    diff /tmp/types.committed.ts /tmp/types.nointl.ts | grep -c '^[<>]'   # 52

`web/lib/barkpark.types.ts` is fenced OUT of this wave → code-unit switch = FILE, not build.

## 4. The fence-safe alternative (pinned collator) costs ZERO regen

    printf "const c=new Intl.Collator('en-US');String.prototype.localeCompare=function(t){return c.compare(String(this),String(t))}\n" > /tmp/pinned.mjs
    cd js && for L in en_US.UTF-8 tr_TR.UTF-8 sv_SE.UTF-8 C; do
      LC_ALL=$L LANG=$L node --import /tmp/pinned.mjs packages/codegen/dist/cli.mjs generate \
        --from ../web/lib/barkpark.schema.json --dataset production --output /tmp/pin.$L.ts; done
    md5 /tmp/pin.*.ts   # all 6f33e5d1165dab07f4c6f869bb4f8bc8 == committed

## 5. Green baseline for both packages

    (cd js/packages/codegen && npx vitest run)              # 7 files / 66 tests passed
    (cd js/packages/create-barkpark-app && npx vitest run)  # 2 files / 21 tests passed

## 6. runGitInit's silent catch leaves a half-initialized repo

Exactly the three commands `post-install.ts` runs, with a failing signer:

    mkdir -p /tmp/gitprobe && cd /tmp/gitprobe && echo hi > a.txt
    printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = /bin/false\n' > /tmp/gc
    GIT_CONFIG_GLOBAL=/tmp/gc GIT_CONFIG_SYSTEM=/dev/null sh -c 'git init -q . && git add -A && git commit -q -m x; echo exit=$?'
    # error: gpg failed to sign the data / fatal: failed to write commit object / exit=128
    ls -d .git && git status --short   # .git ; A  a.txt   → staged, zero commits, user told nothing

`printNextSteps` declares `skipGit` in its options interface but never reads it (grep: one hit, line 11).
