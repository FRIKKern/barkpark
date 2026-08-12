# Re-derivation: paper-excellence evidence durability + guerrilla↔main parity (2026-08-12)

Verifier v6, paper-excellence wave. Every row below re-derives a fact stated in the wave Paper.

## 1. The archived evidence is byte-identical to the scratchpad originals

```sh
cd /Volumes/SATECHI/github/barkpark/tooling/paper-excellence/evidence
shasum -a 256 -c MANIFEST.sha256          # 27 files, all OK
wc -c erasure.html                        # 55094
```

Mutation proof that the manifest can fail (restore afterwards):

```sh
cp shot.mjs /tmp/shot.mjs.bak && printf '\n// tamper\n' >> shot.mjs
shasum -a 256 -c MANIFEST.sha256 | grep FAILED    # shot.mjs: FAILED
cp /tmp/shot.mjs.bak shot.mjs
```

## 2. erasure.html is self-contained (no external asset can rot)

```sh
grep -oiE '(src|href)="[^"]{0,80}' tooling/paper-excellence/evidence/erasure.html    # zero hits
```

## 3. The baselines photograph origin/main's code

Baselines were shot against `https://guerrilla.barkpark.cloud/papers/<slug>` (see
`shot.mjs` line 8). Three independent checks:

```sh
# a) build identity baked at COMPILE time (api/lib/barkpark/build_info.ex)
curl -s https://guerrilla.barkpark.cloud/status.json | python3 -m json.tool | grep commit
git rev-parse origin/main                    # 20dd241ad9… — matches "20dd241ad"

# b) the deployed checkout has NO tracked drift
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'cd /opt/barkpark && git rev-parse HEAD && git status --porcelain'
# HEAD=20dd241ad99819e40bd522c7f5b5e086d34b42f3 ; 9 lines, ALL "??" (untracked)

# c) strongest: main's paper CSS appears verbatim in the served page
curl -s https://guerrilla.barkpark.cloud/papers/heggemsnes-act > /tmp/gp.html
git show origin/main:api/assets/paper-surface/paper-surface.css > /tmp/ps_main.css
python3 -c "
import re;h=open('/tmp/gp.html',errors='replace').read()
s=re.search(r'<style[^>]*>(.*?)</style>',h,re.S).group(1)
print(open('/tmp/ps_main.css').read() in s)"      # True
```

## 4. Limits of the baselines (do not overclaim them)

```sh
grep -n 'fullPage\|deviceScaleFactor\|viewport' tooling/paper-excellence/evidence/shot.mjs
# fullPage:false, deviceScaleFactor:1, viewport 1200 tall
file tooling/paper-excellence/evidence/shots/*.png | head -1   # 1440 x 1200
file tooling/paper-excellence/evidence/full.jpeg               # 2400 x 21430 (artifact side IS full-page)
```

Twin side = above-the-fold only at 1x; artifact side = full page at 2x. Any
regression panel built on these compares unlike captures below the fold.

## 5. shot.mjs is not portable as archived

```sh
grep -n "node_modules\|const OUT" tooling/paper-excellence/evidence/shot.mjs
```

Both the Playwright import and the output dir are absolute machine paths, and the
output dir is the ephemeral scratchpad. Chromium itself still works:

```sh
node -e "import('/Volumes/SATECHI/github/barkpark/js/node_modules/node_modules/playwright/index.mjs').then(async({chromium})=>{const b=await chromium.launch();console.log(b.version());await b.close()})"
# 147.0.7727.15
```

## 6. Free corroborations picked up en route (live CSS, not source)

```sh
python3 -c "
import re;h=open('/tmp/gp.html',errors='replace').read()
s=re.search(r'<style[^>]*>(.*?)</style>',h,re.S).group(1)
print('justify:',len(re.findall(r'text-align\s*:\s*justify',s)))
print(re.findall(r'--bp-body-size\s*:\s*[^;]+',s))
print(re.findall(r'\.bp-paper-shell\s*\{[^}]*\}',s))"
# justify: 0
# ['--bp-body-size: var(--tok-reading-body-size)']
# ['.bp-paper-shell { max-width: 820px; margin: 0 auto; padding: 32px 24px 96px; }', ...]
```
