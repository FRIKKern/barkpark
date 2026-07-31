# Re-derivation recipes — git-ref clone lane mechanics (jarl-platform-followups wave, 2026-07-31)

Verifier lane `clone-sha-mechanics`: does `git init` + `git fetch --depth 1 origin <sha>`
+ `checkout FETCH_HEAD` actually work against real GitHub for `FRIKKern/jarl-website`
(public, anonymously clonable), for the tip sha AND for older non-advertised shas?
All commands run in a FRESH `mktemp -d`, anonymously (`GIT_TERMINAL_PROMPT=0`,
`-c credential.helper=` to defeat the macOS keychain helper). Client: git 2.39.2.
Repo tip at time of run: `2d41fa99f4d44d49eb33e368e500117fae42f4c2`; its parent
`1405b8e1c46bbac81634ed6e57e2b3e68519b1fb`; root commit `16ffa225b3a400c041ed7e3633f27824df15e871`
(13 commits total).

| # | Claim | Command |
|---|-------|---------|
| 1 | GitHub advertises only HEAD/refs/heads/main; ONLY the tip sha is an advertised ref | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/jarl-website.git; GIT_TERMINAL_PROMPT=0 git ls-remote origin HEAD refs/heads/main` |
| 2 | Depth-1 fetch of the ADVERTISED tip sha succeeds; `checkout FETCH_HEAD` yields a working tree at that sha | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/jarl-website.git; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin 2d41fa99f4d44d49eb33e368e500117fae42f4c2 && git checkout -q FETCH_HEAD && git log -1 --format=%H && ls` |
| 3 | Depth-1 fetch of an UNADVERTISED older sha (the parent) succeeds identically — GitHub serves reachable-SHA1-in-want | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/jarl-website.git; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin 1405b8e1c46bbac81634ed6e57e2b3e68519b1fb && git checkout -q FETCH_HEAD && git log -1 --format=%H` |
| 4 | Depth from tip is irrelevant: the ROOT commit (12 back) fetches at depth 1 just the same; `.git/shallow` pins exactly that sha | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/jarl-website.git; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin 16ffa225b3a400c041ed7e3633f27824df15e871 && git checkout -q FETCH_HEAD && git log -1 --format='%H %s' && cat .git/shallow` |
| 5 | An UNREACHABLE sha is refused server-side with `upload-pack: not our ref` (exit 128) — the lane's force-push / GC failure mode | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/jarl-website.git; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin 0000000000000000000000000000000000000001; echo exit=$?` |
| 6 | The GUESSED FALLBACK (shallow branch fetch, then checkout the sha) is BROKEN for any non-tip sha: `fatal: reference is not a tree` | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/jarl-website.git; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin main; git checkout -q 1405b8e1c46bbac81634ed6e57e2b3e68519b1fb; echo exit=$?` |
| 7 | ABBREVIATED shas are refused (`couldn't find remote ref`) — the claim envelope must carry the full 40-char sha | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/jarl-website.git; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin 1405b8e; echo exit=$?` |
| 8 | An inaccessible (private/nonexistent) repo fails as an AUTH prompt, not a 404 — `could not read Username for 'https://github.com'` under `GIT_TERMINAL_PROMPT=0` | `D=$(mktemp -d); cd $D; git init -q .; git remote add origin https://github.com/FRIKKern/definitely-not-a-real-repo-xyz.git; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin 2d41fa99f4d44d49eb33e368e500117fae42f4c2; echo exit=$?` |
| 9 | The builder's only artifact lane today is `file://`; anything else is a hard error string | `git show origin/main:internal/builder/builder.go \| sed -n '389,405p'` |
| 10 | `site-runtime-install.sh` ASSUMES git is present (uses `git clone` with no install step) and hardcodes the arm64 Go tarball at the `install go` step | `git show origin/main:deploy/site-runtime-install.sh \| sed -n '36,52p'` |
