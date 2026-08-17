<!-- doc-tier: cold | canonical-for: pe-w8-leakage-audit-evasion-rederivation | budget: 900tok -->

# pe-w8 — leakage-audit evasion surface (re-derivation recipe)

Origin/main blob under audit: `tooling/paper-excellence/harness/leakage-audit.sh`
= `git hash-object` **4b48308b852cc1b9f329c8c286204e056da3a87f** (matches `git ls-tree origin/main`).

## Re-derive the selftest pass

    SC=$(mktemp -d)
    git show origin/main:tooling/paper-excellence/harness/leakage-audit.sh > $SC/la.sh
    bash $SC/la.sh --selftest ; echo exit=$?
    # -> "SELFTEST PASS", exit=0. CLEAN passes, LEAKY fails on all 4.

## Re-derive the evasion result (audit catches 1 of 8 warm reads)

BP stub feeds a controlled guide so the allowlist is {paper-authoring-excellence, eight-minute-erasure}:

    printf '#!/usr/bin/env bash\n[ "$1" = paper ] && [ "$2" = view ] && echo "see bp paper view eight-minute-erasure"; exit 0\n' > $SC/bp; chmod +x $SC/bp

Transcript of 8 warm reads of `heggemsnes-act` (all REAL bp verbs / real tools):

    bp doc get paper heggemsnes-act                         # CAUGHT (LEAK)
    bp doc query paper --filter slug=="heggemsnes-act"      # SLIP  (real content read)
    bp doc revision rev-abc123                              # SLIP  (real content read)
    bp paper capture https://.../papers/heggemsnes-act      # SLIP  (real paper read by URL)
    bp doc backlinks paper heggemsnes-act                   # SLIP  (real graph read)
    curl -s https://.../papers/heggemsnes-act               # SLIP  (non-bp)
    WebFetch(url=.../papers/heggemsnes-act)                 # SLIP  (tool name != "Bash")
    B=/tmp/.bin/bp; $B paper view heggemsnes-act            # SLIP  (regex needs literal `bp`)

    BP=$SC/bp bash $SC/la.sh $SC/evade2.jsonl ; echo exit=$?
    # -> "slug-bearing reads seen (1): heggemsnes-act" ; FAIL 1 finding ; exit=1
    # Only `bp doc get` is detected. 7 warm-read channels pass the audit vacuously.

## Gap map (pattern @ line on blob 4b48308)

| channel | line | why it slips |
|---|---|---|
| read detection is verb-whitelist, not deny-list | 130,133 | only `paper view/pull` + `doc get` are treated as slug reads |
| `bp doc query` (GROQ-lite content read) | 133 | sub != "get" |
| `bp doc revision` (fetch content by rev id) | 133 | sub != "get" |
| `bp paper capture <url>` (renders a paper) | 130 | sub != "view/pull" |
| `bp doc ls paper` (slug enumeration) | 124 | not search/task; not a slug read |
| raw `curl`/`wget` to /papers/<slug> | 95 | BP_CALL matches literal `bp` only; curl reachable — spawn-cold PATH has /usr/bin |
| non-Bash tool (WebFetch/Read) | 67 | walk() captures only `name=="Bash"` |
| env-var / alias indirection `$B …` | 95 | regex requires literal `bp`, not `$B`/alias |

All channels are REACHABLE in the cold sandbox: spawn-cold.sh gives the child Bash + `/usr/bin`
on PATH (curl live) and the full bp binary (all verbs live). Enumeration + read compose into a
complete undetected warm-read path: `bp doc ls paper` -> `bp doc query paper` / `bp paper capture`.

Fable ruling needed pre-ignition: harness amendment (extend read detection to the real read
verbs + a non-bp HTTP/non-Bash-tool guard) OR explicit accepted-risk (cold agent has no repo/memory
to learn foreign slugs; `bp search`/`bp task` discovery IS hard-failed; residual channels accepted).
Not a rubric edit either way.
