# Re-derivation recipes — charter premise smoke, truth-grip wave 11 (verify, 2026-07-28)

Head at time of measurement: `origin/main` = `a9638ecefb3e98df6c7343455dde31553367229d`.
Charter read is ALWAYS from origin, never a working copy.

## R1 — pull the charter from origin and index its decisions

```bash
cd /Volumes/SATECHI/github/barkpark && git fetch -q origin && git rev-parse origin/main
git show origin/main:.claude/workflows/bp-truth-grip-charter.md > /tmp/tgw11-charter.md
wc -l /tmp/tgw11-charter.md            # 2584
grep -n '\*\*D9[4-9]\|\*\*D1[01][0-9]' /tmp/tgw11-charter.md
```

## R2 — print ONE decision verbatim, whole (not `-A14`, which truncates D94/D95/D116)

```bash
d=D94; awk -v d="$d" 'BEGIN{p=0} /^- \*\*D[0-9]+ /{ if(p)exit; if($0 ~ ("\\*\\*"d" "))p=1 } p{print NR": "$0}' /tmp/tgw11-charter.md
```

## R3 — D111's launder site: the charter names :176, main carries it at :171 AND :176

```bash
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | grep -n 'r.status !== 0'
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | grep -n 'EPIC ='
```
Expect two hits (`171`, `176`) and `58:const EPIC = 'task-47bc4168392dec17';`.

## R4 — D113's invariant vs its digit

```bash
git ls-tree --name-only origin/main tooling/grip/test/ | wc -l   # 17, not D113's 16
git ls-tree --name-only origin/main tooling/grip/test/ | grep record   # empty: no record.test.mjs
```

## R5 — D119(b) both close-by-content commits are ancestors of main

```bash
for c in 8e3c9fbb7 0f3a881b5; do git merge-base --is-ancestor $c origin/main \
  && echo "$c ANCESTOR: $(git log -1 --format=%s $c)"; done
```

## R6 — D109's "polarity discarded at the boundary" is narrower than worded

```bash
git show origin/main:tooling/grip/adjudicate.mjs | sed -n '253,263p'   # ruling() has no `admits` KEY…
git show origin/main:tooling/grip/rerun.mjs      | sed -n '860,862p'   # …but decorate() stamps r.admits
git show origin/main:tooling/grip/adjudicate.mjs | sed -n '122,135p'   # REFUSAL branch: 6-key literal, undecorated
```
The real hole: `screenedRerun`'s refusal branch returns `{command,verdict,scope,ran,ms,reason}` with
no `admits`, so `ruling.rerun.admits.absence` TypeErrors on every REFUSED command — including the
`node …` probe a seal must run to state its own L3 ceiling (D96).

## R7 — NEW: `cli.mjs --selftest` TRUNCATES stdout when it is a pipe (exit stays 0)

```bash
cd /Volumes/SATECHI/github/barkpark
node tooling/grip/cli.mjs --selftest > /tmp/st.txt 2>&1; echo "exit=$?"; wc -l /tmp/st.txt; tail -1 /tmp/st.txt
node tooling/grip/cli.mjs --selftest 2>&1 | wc -l
```
File: 23 lines, `all 15 controls fired as designed.`, exit 0.
Pipe: **7 lines**, cut mid-word, verdict line gone, exit still 0.
`node tooling/grip/ledger.mjs --selftest | tail -2` does NOT truncate (`selftest: 19/19 controls
fired`), so it is cli.mjs-specific. Any CI job or evidence capture that PIPES the D95 command records
a green with no verdict in it.
