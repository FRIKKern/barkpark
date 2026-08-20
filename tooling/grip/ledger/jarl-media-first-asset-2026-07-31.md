# Re-derivation recipes — jarl media first asset (Epic 9 wave 1, 2026-07-31)

Verifier lane [media-first-asset]: run the REAL image upload against the live jarl
instance and characterize the pipeline end to end — exact upload response shape,
relative-vs-absolute url, rendition timing and geometry, and whether the missing
`access-control-allow-origin` on `/media/*` is real.

Two assets were created and are DELIBERATELY NOT deleted (first media objects on the
instance; Decide reuses asset A):

- **A** `cfda3803-3570-4fd9-83fe-c61f3d4ce2ea` — `2026/07/jarl-media-proof-ce8ebb58.png` (via `bp media upload`)
- **B** `ad2dc36c-9ccd-4ff8-bb6d-570eb6702f7a` — `2026/07/proof-b-e9366738.png` (via raw curl, to capture the exact 201 body `bp` swallows)

Rows re-derive from a clean checkout + network. Token rows need a jarl admin token in
`~/.config/barkpark/config.json` (never echo it).

| # | Claim | Command |
|---|---|---|
| 1 | The media library was EMPTY before this run — asset A is the instance's first media object | `bp -s https://jarl.barkpark.cloud media ls --json` (pre-state was `{"assets":[],"count":0,…}`) |
| 2 | Upload succeeds as admin: `POST /media/upload` → **201**. The admin token DOES carry media write scope on jarl | `bp -s https://jarl.barkpark.cloud media upload <file> --yes` (prints `id: <uuid>` only) |
| 3 | The EXACT 201 body is `{id,size,filename,path,url,createdAt,mimeType,originalName,assetDocId}` — `url` is **relative** (`/media/files/2026/07/…png`) and `assetDocId` IS present | `curl -s -D- -X POST https://jarl.barkpark.cloud/media/upload -H "Authorization: Bearer $TOK" -F "file=@proof.png"` |
| 4 | The relative url is structural, not incidental: the controller string-interpolates `url: "/media/files/#{file.path}"` with no origin, on origin/main | `git show origin/main:api/lib/barkpark_web/controllers/media_controller.ex \| awk '/defp render_file\(/,/^  end/'` |
| 5 | `assetDocId` is a **DRAFT** id (`drafts.asset-<uuid>`) and the asset doc carries `_draft: true`. Nothing publishes it. Any published-perspective reference to the asset doc will miss | `bp -s https://jarl.barkpark.cloud media get cfda3803-3570-4fd9-83fe-c61f3d4ce2ea --json \| python3 -m json.tool \| grep -E '_draft\|assetDocId'` |
| 6 | `mediaAsset` is not a queryable content type on jarl — `doc ls mediaAsset` is `not_found`, so the media library is the only handle on the asset | `bp -s https://jarl.barkpark.cloud doc ls mediaAsset --json` |
| 7 | EVERY url in the asset record is relative: `url`, `originalUrl`, `previewUrl`, `thumbnailUrl`, `cdnUrls.*`, `renditions.*` — zero absolute urls anywhere in the pipeline output | `bp -s https://jarl.barkpark.cloud media get <id> --json \| grep -o 'https://' \| wc -l` (→ 0) |
| 8 | The relative url 404s on the site origin — there is no `/media` proxy on jarl.no (and `next.config.ts` has no `rewrites`) | `curl -s -o /dev/null -w '%{http_code}\n' https://jarl.no/media/files/2026/07/jarl-media-proof-ce8ebb58.png` (→ 404) · `cat jarl-website/next.config.ts` |
| 9 | Anon GET of the blob on the API origin is **200**, `content-type: image/png; charset=utf-8`, `cache-control: public, max-age=31536000, immutable` — public serving works, no auth | `curl -s -D- -o /dev/null https://jarl.barkpark.cloud/media/files/2026/07/jarl-media-proof-ce8ebb58.png` |
| 10 | Renditions are **synchronous and ready on first request** — hero is 200 at t0, byte-identical (`etag "13856-TDNSU77"`, 13856 bytes) at t+70s. No 202/pending/async state exists | `curl -s -D- -o /dev/null https://jarl.barkpark.cloud/media/renditions/<id>/hero` twice, 30s+ apart |
| 11 | All four presets serve 200: `hero` webp, `thumb`/`preview`/`og` jpeg. A bogus preset name is 404 | `for r in hero thumb preview og nope; do curl -s -o /dev/null -w "$r %{http_code} %{content_type}\n" https://jarl.barkpark.cloud/media/renditions/<id>/$r; done` |
| 12 | Rendition geometry is FIXED-TARGET and **upscales**: a 200×100 source yields hero 1920×960, preview 1600×800, og 1200×630, thumb 320×160. Source images below 1920w will ship blurry heroes | download each preset, then `python3 -c "from PIL import Image;im=Image.open('r-hero.bin');print(im.format,im.size)"` |
| 13 | **No `access-control-allow-origin` on any media response** — neither blob nor rendition, with or without `Origin: https://jarl.no`. Preflight `OPTIONS` returns 204 with no CORS headers either | `curl -s -D- -o /dev/null -H 'Origin: https://jarl.no' <blob url> \| grep -i access-control` (→ no output) |
| 14 | Root cause at source: `scope "/media"` GETs `pipe_through(:api)`, and the `:api` pipeline contains NO CORS plug. `PublicCors` (which sets `access-control-allow-origin: *`) exists but is wired only at router.ex:649 | `git show origin/main:api/lib/barkpark_web/router.ex \| sed -n '2054,2061p'` · `git show origin/main:api/lib/barkpark_web/router.ex \| awk '/^  pipeline :api do/,/^  end/'` · `grep -rn PublicCors api/lib/barkpark_web/router.ex` |
| 15 | The missing ACAO does **not** break `<img>` (images are not CORS-gated). It breaks only fetch/XHR consumers — i.e. the asciinema cast fetch, not the image path | rows 9 + 13 + the asciicast block reading `data-cast-src` via fetch |
| 16 | The portable-doc `image` block emits `<img src="${b.src}">` **verbatim** — no baseUrl, no BarkparkImage, no rendition preset. A stored relative url in a paper block is a guaranteed 404 on jarl.no | `node -e "const s=require('fs').readFileSync('<extracted>/dist/chunk-IKLDVSPO.mjs','utf8');const i=s.indexOf('var image =');console.log(s.slice(i,i+600))"` (extract `jarl-website/vendor/barkpark-react.tgz`) |
| 17 | The `image` block has fields `src/alt/width/height` and **no caption** — the caption carrier for kilde-law is the `figure` block (`{child, caption}`), which also gives the bold "Figure N." run-in | same file, `s.indexOf('var figure =')` |
| 18 | `BarkparkImage` (the React component, NOT the portable-doc block) DOES absolutize: `baseUrl + inline` when the stored url starts with `/`. So the doctrine is "pass baseUrl" for components and "store absolute" for portable-doc blocks — two different rules | `cat <extracted>/dist/image.d.ts` · `node -e "…indexOf('function computeImageSrc')"` |
| 19 | The engine's id-only fallback route `${baseUrl}/images/<id>` **does not exist on jarl** — 404 for both the media id and the asset doc id | `curl -s -o /dev/null -w '%{http_code}\n' https://jarl.barkpark.cloud/images/cfda3803-3570-4fd9-83fe-c61f3d4ce2ea` |
| 20 | `bp media upload` prints only `id: <uuid>` in human mode and has no `--json` path of its own — the response shape is invisible from the CLI; use raw curl (row 3) to see it | `bp -s https://jarl.barkpark.cloud media upload <file> --yes` |
| 21 | No prior ledger row covers media upload / renditions / media CORS — this is the first derivation | `grep -rln "media/renditions\|PublicCors" tooling/grip/ledger/` (→ no hits before this file) |
