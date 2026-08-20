<!-- doc-tier: agent | canonical-for: pe-w8-rulings-package-probes | budget: 800tok -->

# pe-w8 rulings-package probes — re-derivation recipes (2026-08-17)

Verifier-round probe recipes behind the wave-8 pre-ignition rulings package
(pe-bl-cold-agent-run). Each command re-derives the fact from scratch.

## 1. Effort is a SEPARATE CLI flag; spawn-cold.sh omits it

```sh
/Users/pelle/.local/bin/claude --help 2>&1 | grep -A1 -- '--effort'
# -> "--effort <level>  Effort level ... (low, medium, high, xhigh, max)"
git show origin/main:tooling/paper-excellence/harness/spawn-cold.sh | sed -n '56p;104p'
# line 56: COLD_MODEL="${COLD_MODEL:-opus}"   (comment claims opus@medium)
# line 104: --model "$COLD_MODEL"             (NO --effort anywhere)
```

Igniting as-is runs the author at bare's default effort — harness fix
(`--effort "${COLD_EFFORT:-medium}"`) required before spawn; not a rubric edit.

## 2. Validate dry-run is HTTP 200 valid:false; BPML table plain-text cells parse clean

```sh
CFG=~/.config/barkpark/config.json
SERVER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"])' $CFG)
TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' $CFG)
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$SERVER/v1/plugins/bulldocs/papers/validate" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"bpml":"<paper><h1>probe</h1><p>x</p></paper>"}'          # -> 200
curl -s -X POST "$SERVER/v1/plugins/bulldocs/papers/validate" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"bpml":"<paper><h1>probe</h1><p>x</p><table><tr><th>a</th></tr><tr><td>1</td></tr></table></paper>"}'
# -> {"valid":false,"violations":[{"code":"label_spine",...}]}  — NO parse/unknown_tag
# violation: <tr>/<th>/<td> text cells are accepted; parser coerces to inline (#11644).
```

So bare-string blank-render is unreachable via `bp paper push` BPML; it needs the
raw-JSON `bp bulldocs publish` arm — an authoring CHOICE (J5), not a door defect.

## 3. Admin bp token prefix is committed on public origin/main

```sh
TOKEN=$(python3 -c 'import json;print(json.load(open("'$HOME'/.config/barkpark/config.json"))["token"])')
git grep -l "${TOKEN:0:12}" origin/main -- tooling/
# -> tooling/grip/fixtures/evidence-corpus.json
#    tooling/grip/ledger/jarl-writability-2026-07-31.md
#    tooling/grip/ledger/pe-w7-landed-check-sentinel-2026-08-17.md
```

Transcript scrub must mask BOTH `sk-ant-*` and this token; rotation is post-seal ops.

## 4. Live guide teaches the tag registry + remedy (R1's door/agent key)

```sh
bp paper view paper-authoring-excellence | grep -niE 'register' | head
# guide names example tags authoring-excellence + bulldocs and maps
# "publish references unregistered tag(s)" -> pick suggestions OR register a type:tag doc
bp doc get paper paper-authoring-excellence -o json | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(d["_rev"],d["_updatedAt"])'
# 2026-08-17T18:5xZ snapshot: cf91fcffedc49235024f7b6352fe53b1 — RE-DERIVE at run start
```
