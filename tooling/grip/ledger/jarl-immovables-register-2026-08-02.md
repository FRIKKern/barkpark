# Immovables register — jarl.no prosjekt-innlegg (proven live 2026-08-02)

Re-derivation recipe for the 14-slug / 23-substring fabrication fence used by Epic 14
(jarl-innleggene-epic). Every row exact-matched against BOTH the rendered live page and
the CMS source of truth on 2026-08-02. Drift = 0/23 on live, 2/23 on the `project` store
alone (those two live in the story paper, see NOTE 2).

## Register (slug -> exact substrings, NFC, whitespace-collapsed)

```json
{
  "oslobukta": ["En kollega ledet arbeidet; jeg var andreutvikler", "med omtrent hver tredje endring som min"],
  "kronprinsparets-fond": ["Sidene var bygget av andre i 2020", "I 2026 bygde jeg neste generasjon alene", "Bygget alene: et monorepo der FLYT-appene deler design og innhold"],
  "spreadsheet-wizard": ["I 2022 bygde Suman Chapai og jeg en Sanity-plugin", "Vi bygde den som Sanity-plugin i 2022, Suman Chapai og jeg", "Prosjektet var hans like mye som mitt", "36 av dem Sumans, 5 mine"],
  "akerbrygge": ["632 av plattformens 879 endringer er mine"],
  "gyldendal": ["nest mest aktive utvikler på gyldendal.no med 179 bidrag"],
  "lunnheim": ["med Stripe og Klarna i kassen"],
  "aquatiq-synk": ["SuperOffice, Shopify, Visma"],
  "galleryspace": ["tretti små endringer", "181 endringer, og telleren går fortsatt"],
  "doey": ["pelle, en egen Mac mini med sin egen GitHub-bruker, som la 1 350 endringer på ni dager"],
  "full-blast": ["Spillet begynner for hånd i nettleseren", "AI-flåten setter i gang gjenoppbyggingen"],
  "nextgen": ["versjon 1.0.147, 335 endringer skrevet alene", "Stille siden oktober 2025"],
  "barkpark-cloud": ["av én person og en flåte av agenter"],
  "hundesteder": ["Alt er designet og bygget fra bunnen, av meg"],
  "ticket-realtime": ["Bygget alene på én måned"]
}
```

Negative row (absence is the immovable): `aquatiq-synk` must contain **no** `%` and no
`prosent` — measured 0 occurrences on the rendered page 2026-08-02.

## Re-derivation

`tagstrip.py` (drops `<script>`/`<style>` bodies FIRST so the RSC payload cannot launder a
match, then strips tags, `html.unescape`, maps U+00A0/202F/2009 to space, collapses runs):

```python
import sys, re, html
raw = sys.stdin.read()
raw = re.sub(r'(?is)<(script|style)\b.*?</\1>', ' ', raw)
txt = html.unescape(re.sub(r'(?s)<[^>]+>', ' ', raw))
for ch in ('\u00a0', '\u202f', '\u2009'): txt = txt.replace(ch, ' ')
sys.stdout.write(re.sub(r'\s+', ' ', txt))
```

Live check (edge truth):
`curl -s https://jarl.no/prosjekter/<slug> | python3 tagstrip.py | grep -qF '<substring>'`

Source check (ISR-immune truth), both stores:
`curl -s 'https://jarl.barkpark.cloud/v1/data/query/production/project?limit=50'` and
`.../paper?limit=100` — both are anonymously readable; grep the doc's JSON blob.

## NOTES a gate author must not skip

1. **ISR makes fetch-once a liar.** `cache-control: s-maxage=60,
   stale-while-revalidate=31535940`; `x-nextjs-cache: HIT` on a plain GET and **STALE**
   even on a cache-busted query string. A post-write gate that fetches once can grade the
   pre-edit render. Poll until fresh, or gate on the CMS API and treat the live curl as a
   second, laggy witness.
2. **Two stores, and they overlap.** 6 of the 23 substrings live in a `paper` (story) doc,
   4 of them in BOTH the `project` doc and the paper — `spreadsheet-wizard` (4 strings, 2
   paper-only), `full-blast` (2, both duplicated), `barkpark-cloud` (1, duplicated),
   `nextgen`'s "Stille siden oktober 2025" also appears in `frikk-tiaret-dossier`. A
   builder who edits one copy silently desyncs the other; a project-only gate reads 2/23
   as DRIFT that isn't.
3. Tag-stripping is not strictly required today (all 23 also match the raw HTML bytes),
   but raw-byte matching can be satisfied by the RSC payload alone — keep the strip.
4. No such gate exists yet: `grep -rln 'hver tredje endring|632 av plattformens|Suman
   Chapai|immovab|urørlig'` over `jarl-website` (minus node_modules/.next) returns nothing,
   and `check-sources.mjs` is scoped to `FIGURE_KINDS = {statBand, duel, lineage}` only.
