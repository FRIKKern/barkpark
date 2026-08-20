# Re-derivation: rendered-page QUAD truth for the innleggene kåring (verify, 2026-08-02)

CDP probe against LIVE https://jarl.no — headless Chrome 150, no playwright, no repo deps.
Probe scripts preserved in the wave session scratchpad (`quadprobe.mjs`, `quadmeasure3.mjs`);
the canonized playwright rig exists UNMERGED at jarl-website commit `a10c3e1`
(branch `loop-epic/width-doctrine-tokenized-measure-figure--0`, task jf-w1-width-tokens-gate-rig,
criterion "PR merged" open).

## Dark mode needs CDP/playwright emulation, and it is REAL

```sh
# Chrome --screenshot cannot set prefers-color-scheme; CDP Emulation.setEmulatedMedia can:
# {"features":[{"name":"prefers-color-scheme","value":"dark"}]}
# Measured on /prosjekter/barkpark: body bg light rgb(235,228,222), dark rgb(16,26,45);
# all 24 QUAD PNGs hash-distinct (shasum -a 256), light/dark pairs differ per page.
```

## The 60s cache serves STALE — fetch-once photographs the old page

```sh
curl -s -D - -o /dev/null https://jarl.no/prosjekter | grep -i 'x-nextjs-cache\|cache-control'
sleep 66
curl -s -D - -o /dev/null https://jarl.no/prosjekter | grep -i 'x-nextjs-cache\|cache-control'
# FETCH1: cache-control: s-maxage=60, stale-while-revalidate=31535940 / x-nextjs-cache: HIT
# FETCH2: same cache-control / x-nextjs-cache: STALE
# -> any rating rig must warm each URL (fetch, discard, re-fetch) before judging it.
```

## Lazy images blank out below-fold captures — in BOTH rigs

```sh
curl -s https://jarl.no/prosjekter | grep -c 'loading="lazy"'   # 12 (all photo cards; 0 eager)
git -C /Users/frikkjarl/Documents/GitHub/jarl-website show a10c3e1:scripts/shoot.mjs | grep -c 'lazy'  # 0
# CDP captureBeyondViewport photographed Scaffy/Bulldocs cards as EMPTY boxes while
# Artwork (SVG) cards drew fine. Rig fix: force img.loading='eager' + await img.complete
# (or scroll-step slower than image fetch) before fullPage capture.
```

## 900px truth: story figure blocks are bp-*, NOT Sections-module

```sh
curl -s https://jarl.no/prosjekter/scaffy | grep -o 'class="bp-[a-z]*' | sort -u
# bp-asciicast / bp-cols / bp-duel / bp-kilde / bp-lineage / bp-role / bp-stat(s) ...
# Counting media only:            scaffy worst run 1486px @1440 (false wall)
# Counting media + bp-* + Sections kinds: scaffy 490px, barkpark 635px, gyldendal 686px,
#   spreadsheet-wizard 1217px (text-only intro, real break), doey 1416px (whole article).
# -> the char-proxy "longest posts break the rule" is REFUTED once section/figure blocks count.
```
