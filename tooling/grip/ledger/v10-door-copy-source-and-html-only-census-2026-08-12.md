# v10 — paper door copy source + body_html-only census (2026-08-12)

Re-derivation recipes for the paper-excellence wave (verifier v10). Every number below
is re-derived by the command under it. Server = guerrilla (`~/.config/barkpark/config.json`,
`https://guerrilla.barkpark.cloud`), admin token.

## 1. The "or HTML payload" manifest string (server-side source)

```
git show origin/main:api/lib/barkpark/plugins/bulldocs.ex | grep -n 'HTML payload'
# 316:          "Publish (upsert) a paper from a portable-doc or HTML payload. " <>
grep -n 'Payload (blocks or body_html)' api/lib/barkpark/plugins/bulldocs.ex   # 328
```

Served live (proof the running system carries the same bytes):

```
curl -s -H "Authorization: Bearer $BP_ADMIN" https://guerrilla.barkpark.cloud/v1/capabilities \
  | python3 -c 'import json,sys;[print(json.dumps(c,indent=1)) for c in json.load(sys.stdin)["commands"] if c["id"]=="bulldocs.publish"]'
```

Copies of the same string that must move with it:

```
git grep -ln "portable-doc or HTML"
# api/lib/barkpark/plugins/bulldocs.ex   <- source of truth
# docs/openapi.json                      <- CI-GATED (.github/workflows/elixir.yml:410-423)
# docs/cli/fixtures/full-manifest.json   <- CLI test fixture (internal/cli/cli_test.go:24)
# tooling/scaffy-duels/fixtures/caps-{brief,full}-2026-07-24.json  <- dated duel fixtures
```

Noun blurb (separate file): `api/priv/plugins/bulldocs/plugin.json:4`.

## 2. bp CLI paper door copy (read-only surface)

```
grep -rn 'read Bulldocs papers' internal/cli      # paper_cmd.go:1543 (usagePaper, def at :1537)
grep -n 'papers:' internal/cli/usage.go           # :110-112 top-level `papers:` section
grep -n 'case "paper":' internal/cli/cli.go       # :464 builtin dispatch (NOT a manifest noun)
bp bulldocs publish --help                        # renders the manifest summary verbatim
```

## 3. Onramp teach block carries ZERO paper copy

```
bp onramp agents-md | python3 -c 'import json,sys;print(json.load(sys.stdin)["files"][0]["content"])' | grep -ci paper   # 0
sed -n '322,350p' internal/cli/onramp_cmd.go      # renderAgentsMDBody — the ONE body
```

Cost of adding one line (mutation proof, no repo write — go `-overlay`):

```
cp internal/cli/onramp_cmd.go $SC/onramp_mut.go   # add one "- `bp paper view …`" line
printf '{"Replace":{"%s/internal/cli/onramp_cmd.go":"%s/onramp_mut.go"}}' "$PWD" "$SC" > $SC/overlay.json
CC=/usr/bin/clang go test -overlay $SC/overlay.json ./internal/cli/ -run TestOnrampAgentsMd -count=1
# FAIL x4: testdata/agents_md.golden, .cursor/rules/barkpark-tasks.mdc,
#          .claude/CLAUDE-BARKPARK.md, docs/setup/CODEX.md
```

(The wrapper gate is `strings.Contains`, so it catches a change to the shared body but
NOT an extra line added only to a wrapper doc.)

## 4. body_html-only census (published perspective)

```
for off in $(seq 0 50 750); do
  curl -s -H "Authorization: Bearer $BP_ADMIN" \
    "https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=50&offset=$off&fields=_id,blocks,content,body,body_html,style,title,_createdAt" \
    -o pages/p$off.json
done
```

Classify with `struct(d) = blocks | content | body.doc | None` (papers store their tree in
THREE different fields — a census that only looks at `blocks` overcounts HTML-only by 2.4x):

| shape | count |
|---|---|
| blocks + body_html cache | 658 |
| blocks, no cache | 33 |
| body.doc (PortableDoc) | 32 (+1 with cache) |
| content list | 9 |
| **body_html ONLY (the HTML door)** | **31 / 764 = 4.1%** |

Cross-surface damage, same reader:

```
bp paper view support-tiers --width 70          # HTML-only: table cells collapse ("SeverityDefinition")
bp paper view spd-inspector-shape-wave-11-2026-07-20 --width 70   # blocks: box-drawn table grid
```
