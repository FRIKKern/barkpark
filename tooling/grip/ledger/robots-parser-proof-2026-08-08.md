# robots.txt candidate bytes — parser proof (anonymous-metering W1 slice 2, D6)

2026-08-08 · verifier `robots-parser-proof` · re-derivation recipes only, no conclusions here.

## Rebuild the parser harness

```bash
mkdir -p /tmp/robots && cd /tmp/robots
# harness: builds both candidate shapes, runs urllib.robotparser AND a local
# RFC 9309 longest-match/wildcard evaluator across the agent x path matrix.
# (source kept in the wave paper; re-author from the two shapes below)
python3 robots_proof.py
```

Shape A (D6 literal — the shape that survived both parsers):

```
User-agent: *
Allow: /papers/
Allow: /sheets/
Disallow: /finder
Disallow: /quiz/
Disallow: /studio
Disallow: /login
Disallow: /s/
```

Shape B1 (default-deny, Allow lines FIRST — also survives both):

```
User-agent: *
Allow: /papers/
Allow: /sheets/
Disallow: /
```

Shape B2 (default-deny, `Disallow: /` FIRST — DIVERGES; urllib denies /papers/):

```
User-agent: *
Disallow: /
Allow: /papers/
Allow: /sheets/
```

Ordering probe, one command:

```bash
python3 - <<'PY'
import urllib.robotparser
for name, txt in (("B1","User-agent: *\nAllow: /papers/\nDisallow: /\n"),
                  ("B2","User-agent: *\nDisallow: /\nAllow: /papers/\n")):
    rp = urllib.robotparser.RobotFileParser(); rp.parse(txt.splitlines())
    print(name, rp.can_fetch("*", "/papers/some-slug"))
PY
```

## Live-box truth (L1)

```bash
curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' https://guerrilla.barkpark.cloud/robots.txt   # api app
curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' https://barkpark.cloud/robots.txt              # cloud console
curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' https://api.barkpark.cloud/robots.txt          # ALSO the cloud console
```

## Repo anchors

```bash
git show origin/main:api/lib/barkpark_web.ex | sed -n '7p'                       # api static allowlist
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '418p'      # cloud static allowlist
git show origin/main:cloud/test/web/static_allowlist_test.exs                    # the pin that must be edited
git grep -rln robots origin/main -- api/test cloud/test scripts/ .github/        # (empty = no smoke exists yet)
```

## Vendor UA-token spot-check

```bash
curl -sSL -A "Mozilla/5.0" https://knownagents.com/agents/gptbot | \
  grep -oiE '(GPTBot|ClaudeBot|CCBot|Applebot-Extended|Bytespider|Amazonbot|OAI-SearchBot|OAI-AdsBot|ChatGPT-User)' | sort -u
```
WebFetch: `https://developers.openai.com/api/docs/bots` ·
`https://support.claude.com/en/articles/8896518-…` ·
`https://developers.google.com/search/docs/crawling-indexing/google-common-crawlers`
