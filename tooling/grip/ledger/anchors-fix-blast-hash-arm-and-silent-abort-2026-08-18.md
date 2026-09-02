<!-- doc-tier: cold | canonical-for: none | budget: 4000tok -->

# anchors-fix-blast — re-derivation recipes (origin/main 541195b5d1)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Every recipe runs against a throwaway `git archive` extract. Nothing touches the shared checkout.

## 0. Build the pristine tree

```sh
D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C "$D" && cd "$D"
bash scripts/docs-anchors-check.sh >/dev/null 2>&1; echo rc=$?      # expect rc=0
```

## 1. Enumerate card anchors that resolve ONLY via the `^#` arm

```sh
for card in docs/cards/*.md; do
  awk '/^## Code anchors/{on=1;next} /^## /{on=0} on && /^- /' "$card" |
  while IFS= read -r line; do
    apath=$(printf '%s\n' "$line" | sed -E 's/^- ([^ ]+) —.*/\1/')
    [ -e "$apath" ] || continue
    for sym in $(printf '%s\n' "$line" | grep -oE '(func|def|defmodule) [A-Za-z_][A-Za-z0-9_.]*[?!]?' | awk '{print $2}'); do
      grep -Eq "(func |def |defmodule |^#).*$sym" "$apath" || { echo "NOMATCH $card $apath $sym"; continue; }
      grep -Eq "(func |def |defmodule ).*$sym" "$apath" \
        && echo "BOTH  $card $apath $sym" || echo "HASHONLY $card $apath $sym"
    done
  done
done
```

Expected on 541195b5d1: **40 BOTH, 0 HASHONLY, 0 NOMATCH**; zero anchor paths end in `.md`.
The `^#` arm is dead code — it protects nothing today.

## 2. Planted-violation pair proving `^#` is the sole cause of a false pass

```sh
# plant: fabricated anchor + a shell-style comment carrying the symbol, in a .go file
python3 - <<'PY'
s=open('docs/cards/cli.md').read(); i=s.index('## Code anchors'); j=s.index('\n- ', i)
open('docs/cards/cli.md','w').write(s[:j]+'\n- internal/cli/cli.go — func totallyFakeSymbolXyz does not exist as code\n'+s[j:])
PY
echo '# totallyFakeSymbolXyz is only a comment' >> internal/cli/cli.go
bash scripts/docs-anchors-check.sh >/dev/null 2>&1; echo with_comment_rc=$?     # expect 0  (VACUOUS)
sed -i '' -e '$d' internal/cli/cli.go
bash scripts/docs-anchors-check.sh >/dev/null 2>&1; echo without_comment_rc=$?  # expect 1  (control red)
```

## 3. §8 widening dry-run (.js/.mjs/.heex/.py/.sh) — READ ONLY

```sh
INC=(--include='*.ex' --include='*.exs' --include='*.go' --include='*.ts' --include='*.tsx' \
     --include='*.js' --include='*.mjs' --include='*.heex' --include='*.py' --include='*.sh')
P=(--exclude-dir=node_modules --exclude-dir=_build --exclude-dir=deps --exclude-dir=.git \
   --exclude-dir=.omx --exclude-dir=.tmp-bp89 --exclude-dir=.claude --exclude-dir=.artifacts)
grep -rHoE '@canonical capability:[A-Za-z0-9._-]+' "${INC[@]}" "${P[@]}" . \
  | sed -E 's/.*capability:([A-Za-z0-9._-]+).*/\1/' | sort | uniq -d     # expect: fleet-presence-staleness
grep -rn '@canonical capability:' --include='*.js' --include='*.mjs' --include='*.heex' \
  --include='*.py' --include='*.sh' "${P[@]}" .                          # expect 9 hits
```

Widening as briefed reds main: 1 duplicate slug (`fleet-presence-staleness`, a PROSE CITATION in
`scripts/pdf-kill-listener-proof.sh:80` colliding with the real marker in
`api/lib/barkpark/tasks/fleet.ex:127`) plus 8 §8(b) failures — 6 of them
`scripts/docs-anchors-check.sh`'s own doc-comment self-references, and
`cloud/priv/static/app.js:16615`, a LEGITIMATELY placed marker whose entry point is
`function instanceAdminAuthority()` — plain JS `function ` is not in §8(b)'s
`(def |func |export )` alternation.

## 4. §1/§2/§3b silent abort under `set -euo pipefail`

Mechanism (empty pipeline element → rc 1 → pipefail → `set -e` kills the assignment):

```sh
printf 'set -euo pipefail\nD=$(mktemp -d); : > "$D/i.md"\nE=$(grep -oE "[a-z]+\\.md" "$D/i.md" | sort -u)\necho REACHED\n' > /tmp/p.sh
bash /tmp/p.sh; echo abort_rc=$?    # prints nothing; abort_rc=1
```

On the real script, three independent plants:

```sh
# §1 — strip the leading '|' from the routing table (grep -E '^\|' matches nothing)
python3 -c "s=open('CLAUDE.md').read();open('CLAUDE.md','w').write('\n'.join(l[1:] if l.startswith('|') else l for l in s.split('\n')))"
bash scripts/docs-anchors-check.sh; echo rc=$?
# prints ONLY '== routing-table targets (CLAUDE.md) ==' then rc=1.
# Line 82's friendly "no routing-table targets found" NEVER prints; §2–§8 never run.

# §2 — INDEX.md with only self-references (second grep -v filters everything)
printf '<!-- doc-tier: agent | canonical-for: doc-index | budget: 4000tok -->\nsee INDEX.md\n' > docs/INDEX.md
bash scripts/docs-anchors-check.sh; echo rc=$?   # dies after '== INDEX entries ==', rc=1, no message

# §3b — rename '## Code anchors' -> '## Code pointers' in all 17 non-card docs (empty grep -rl)
bash scripts/docs-anchors-check.sh; echo rc=$?   # dies after '== Code anchors in non-card docs ==', rc=1
```

§1 and §2 are fail-closed-but-mute. §3b is a **FALSE RED**: zero non-card docs carrying a
Code-anchors section is a legitimate state, not a violation.

## 5. Bonus: `$sym` is interpolated UNQUOTED into an ERE

```sh
mkdir -p /tmp/rp && cd /tmp/rp
printf 'defmodule Barkpark_Media_Delivery_Retriever do\nend\n' > a.ex
grep -Eq "(func |def |defmodule ).*Barkpark.Media.Delivery.Retriever" a.ex && echo DOT_WILDCARD_PASS
printf 'def default_enabled(x), do: x\n' > b.ex
grep -Eq "(func |def |defmodule ).*default_enabled?" b.ex && echo QMARK_OPTIONAL_PASS
```

Both print. `.` is any-char and `?` makes the preceding char optional, so a dotted-module anchor
and a `?`-suffixed predicate anchor are both satisfied by a symbol that is not the declared one.
Fix direction: `grep -F`-style literal matching, or escape `$sym` before interpolation.
