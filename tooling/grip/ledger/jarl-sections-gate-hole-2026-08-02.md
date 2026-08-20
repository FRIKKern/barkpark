# jarl.no — the sections gate hole (re-derivation recipe)

Epic 14 wave `jarl-innleggene-wave-2026-08-02`, verifier `sections-render-and-gate-extension`.
Every row below is a command that re-derives the fact from scratch. Repo copies untouched.

## 1 · check-sources is green — and green on nothing a reader sees

```sh
cd ~/Documents/GitHub/jarl-website && set -a && . ./.env.local && set +a && node scripts/check-sources.mjs
# check-sources: scanned 3 pages + 20 projects (45 sections, 14 figure sections)
# and 10 papers (15 figure blocks): 88 figure data checked.  exit 0
```

All 14 figure sections live on the six story-paper projects, whose `<Sections>`
never render (`src/app/prosjekter/[slug]/page.tsx:154` — `{hasStory ? null : <Sections …>}`):

```sh
cd ~/Documents/GitHub/jarl-website && set -a && . ./.env.local && set +a && node -e '
const U=process.env.BARKPARK_URL.replace(/\/$/,""),T=process.env.BARKPARK_READ_TOKEN;
const g=async t=>(await(await fetch(`${U}/v1/data/query/production/${t}`,{headers:{Authorization:`Bearer ${T}`}})).json())?.result?.documents??[];
const papers=await g("paper"),projects=await g("project");const ids=new Set(papers.map(p=>p._id));
const F=new Set(["statBand","duel","lineage"]);let rend=0,dead=0;
for(const p of projects){const st=p.story?._ref??p.story?._id??p.story;const live=!(st&&ids.has(st));
 for(const s of (p.sections??[])) if(F.has(s.kind)) live?rend++:dead++;}
console.log({rend,dead});'
# { rend: 0, dead: 14 }
```

## 2 · widening FIGURE_KINDS changes nothing (red delta = 0)

```sh
SP=<scratchpad>; cp ~/Documents/GitHub/jarl-website/scripts/check-sources.mjs $SP/check-sources-widened.mjs
# edit line 31 → new Set(["statBand","duel","lineage","split","timeline","featureGrid","steps"])
cd ~/Documents/GitHub/jarl-website && set -a && . ./.env.local && set +a && node $SP/check-sources-widened.mjs
# 45 sections, 33 figure sections … 88 figure data checked.   exit 0 — SAME 88, SAME green
```

Cause: the gate keys on `item.value` / `item.value2`, and only statBand/duel/lineage
authors ever fill them (live tally: split 20 items / 0 with value, timeline 19/0,
featureGrid 10/0, steps 8/0). The uncovered numbers are in PROSE:

```sh
# 250 prose fields on pages+projects; 42 contain a digit; ~100 numeric tokens — none gated
```

## 3 · the 900px rule is VERTICAL and encoded nowhere

Charter: «intet tekstløp over ~900px uten et ærlig visuelt moment» — run length, not column width.

```sh
grep -rn "900" ~/Documents/GitHub/jarl-website/src/app/globals.css
# only --dur-drawer: 900ms (animation). The rule has never been encoded.
```

Section prose is width-bounded by CSS already (`.head` var(--measure)=672px, `.itemBody` 46ch,
split 38ch, timeline 62ch, quote 44rem, callout 52rem) — a width gate would find nothing.

## 4 · what a section-page gate would have to parse

`Sections.tsx` is React + CSS modules; there is no string emitter for it
(`renderToStaticMarkup` appears nowhere in src/ or scripts/), and node cannot import it:

```sh
cd ~/Documents/GitHub/jarl-website && node --input-type=module -e 'await import("./src/components/Sections.tsx")'
# ERR_UNKNOWN_FILE_EXTENSION: Unknown file extension ".tsx"
```

The only static handle is the deployed SSR HTML, which does carry resolvable class names:

```sh
curl -s https://jarl.no/prosjekter/oslobukta | grep -o 'class="Sections-module__[^"]*"' | sort -u
# Sections-module__k-WNVq__itemBody / __overline / __split / __splitCol / __splitTitle
```

Hashed local names end in `__<localName>`, so HTML → Sections.module.css selector is a
parseable join. That buys WIDTH. It does not buy HEIGHT — vertical run length needs a
layout engine (screenshot rig / CDP), and no browser dep exists in package.json.
