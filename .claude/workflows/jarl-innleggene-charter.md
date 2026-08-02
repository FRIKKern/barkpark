# Charter: Epic 14 — Innleggene (jarl-innleggene-epic)

Wave paper: `jarl-innleggene-wave-2026-08-02` (guerrilla). Sist revidert av Decide 2026-08-02 etter full survey- (14/14) og verify-runde (7/7, alle med kjørte bevis).

## Ønsket, ordrett
«Gjør klar og utfør en epic cycle for å finne ut de beste prosjektene - sånn innleggs-messig - hvilke er best - og rate alle - prøv å sjekk standaren - øk standaren - alle skal være premium top level»

## Kontekst (rettet mot verifisert grunnsannhet 2026-08-02)
jarl.no kjører på dedikert Barkpark-instans (https://jarl.barkpark.cloud, admin-token i /tmp/jarl_admin_token; CMS-skriving fra NØYTRAL cwd). 20 `project`-dokumenter; **live slugs er `polyflor-ordre` og `aquatiq-synk`** (charterets tidligere «polyflor»/«aquatiq» var feil). 6 story-papers (scaffy-, bulldocs-, barkpark-cloud-, svgloop-, spreadsheet-wizard-, full-blast-historien). Renderer-regel som binder løftene: **et prosjekt med `story` rendrer ALDRI sections** (`prosjekter/[slug]/page.tsx:154`) — story-innleggs medier må være Paper-blokker, aldri mediaBand.

Verifiserte fakta enhver bygger skal stole på:
- **ISR-fella**: `s-maxage=60, stale-while-revalidate=31535940`. Én fetch kan fotografere en side som er opptil ett år gammel. Alle gates/skjermbilder varmer (fetch → vent → fetch igjen) eller leser CMS-APIet (anonymt lesbart, ISR-immunt).
- **Skrivevei bevist**: ikke-admin `bpapp_`-token (read+write) laster opp media ende-til-ende. Multipart-feltet heter `file` (ikke `upload`); publish-mutasjon krever `id` OG `type`; opplastede assets fødes som draft og publiseres separat; 201-svaret bærer kun relativ URL. Dommere kan gis read-only-token (403-bevist skrivesperre).
- **Rigg FINNES** — bygg aldri fra null: `epic13/capture-jarl.mjs` (scratchpad, flyktig, kjørt 2026-08-01, forcerer lazy→eager) + `scripts/shoot.mjs` (git-blob `82b7e637` på umerget lokal branch `loop-epic/width-doctrine-tokenized-measure-figure--0`). Kjente defekter: shoot.mjs mangler lazy-håndtering; probene ser bare `.bp-paper-surface` (blind på 14 sections-sider); branchen kolliderer på `scripts/check-measure.mjs` (main sin emitter-variant beholdes; kun shoot.mjs-blobben hentes).
- **Epic-13-medie-pipelinen overlever** i scratchpad og er kjørt i dag (driver.sh, frames43/compose43.py, recrop/, epic9frames/). Kanoniske cast-dimensjoner er **100×30** — mediedoktrinens «80×24» er feil og rettes; compose43-metrikkene er målt på 100×30.
- **Kilderepoer rettet**: polyflor → `polyflor-next-order-app-2024` (103 commits), frick-design-system → `frick-monorepo` (506), ticket-realtime → `frickin-real-time` (1535, DELT med Full Blast — klippforbudet gjelder begge innlegg). `jarl-website-2023-archive` er en uendret Tailwind-demo uten ett eneste klientfaktum: **STRØKET som kilde** (ren fabrikasjonsfare). `frikk-tiaret-dossier` er et paper på jarl-instansen, ikke et repo.
- **Ingen unlisted-modus på jarl**: draft er usynlig også for teamet; publisering = sitemap + RSS, ubetinget. Det tredje alternativet («stille hjørne») finnes ikke.

## Husets lover (presisert av målt sannhet)
- **Språkloven** (Epic 12): korte setninger, aktive verb, du/vi, ingen lange tankestreker, ingen kalkert engelsk.
- **Kilde-loven**: hver påstand og hvert bilde bærer opphav. Presisering: bilde-kilde bor i caption («Skjermbilde av <URL>, fanget <dato> — <hva>» for klientsider; «Kilde: opptaket <cast>, tatt opp <dato> …» for terminalstills); mønsteret dato+opphav holder allerede på 36/47 assets og blir gate (`check-image-kilde.mjs`). `Kilde:`-prefiks-grep er FEIL gate (kun 12/45 bruker det). Dokumenter lagrer **relative** `/media/files/…`-adresser (Next-proxy + CORS); mediedoktrinens absoluttadresse-lov er død i praksis og rettes i doktrinen.
- **900px-regelen**: VERTIKALT tekstløp. Både section-kinds og bp-*-story-blokker teller som ærlige visuelle momenter for PACING; kun kilde-stemplede fangster/figurblokker teller for EVIDENS; `Band` er layoutprimitiv og teller aldri. Målt (rendret, 2026-08-02): de lengste innleggene BESTÅR (scaffy 490px, barkpark 635px @1440); bruddet er spreadsheet-wizard-introen (1217px); bunn-seksens feilende dimensjon er **TYNNHET, ikke tekstvegger** — char-proxyen var invertert.
- **Tinholt-grammatikken**: sidenivå-tema, hårlinjer artikulerer, null skygger, radius 0, fotografi bærer varme; terminalstills skalerer ikke til romstørrelse. Dømmes i QUAD {1440,390}×{lys,mørk} — mørk er et ekte marineblå-tema (rgb(16,26,45)), kun nåelig via emulering.
- **Evidensloven for roller**: det maskinsjekkbare registeret er **23 eksakte substrenger over 14 slugs + én negativrad** (aquatiq-synk: ingen «%», ingen «prosent») — kanonisk i `tooling/grip/ledger/jarl-immovables-register-2026-08-02.md`, 23/23 PASS live i dag. **6 av strengene bor i TO dokumenter** (project + story-paper/dossier) — redigering av én kopi desynker den andre; gaten sjekker begge lagre via CMS-APIet. Bruk registerets strenger ordrett; digestens ASCII-foldede sitater («flate», «sma») matcher aldri.
- **Eierens stemme**: innlegget svarer «hva tilbyr dette / hvordan brukes det» tidlig; ingen commit-oppramsing i prosa. Artwork-fallback på kort er ærlig (aldri tom boks), men aldri premium for et programvareprosjekt med ekte UI å vise.

## Rubrikken (vedtatt HER — paper-slicen kanoniserer, endrer ikke)
7 dimensjoner, **PASS/FAIL/NA** per dimensjon. **Premium = null FAIL — aldri et snitt** (GRADE-CRITIQUEs falske 100). NA der dimensjonen ærlig ikke gjelder, aldri 0. Dømmeenhet: **RENDRET side i QUAD {1440,390}×{lys,mørk}**, aldri JSON. frontend-design-skillen er generativ: informerer FIKSER, aldri dommer.
1. **SPRÅK** — språkloven holder: setningsdisiplin, null lange tankestreker, norsk eierstemme.
2. **KILDE** — hvert figurdatum og hver fangst bærer gyldig opphav (caption-mønster / source-ref); ingen ukildede tall.
3. **SUBSTANS** — svarer «hva tilbyr dette / hvordan brukes det» på første skjerm; et nesten-tomt innlegg FEILER her (ikke på pacing).
4. **PACING** — intet rendret tekstløp over ~900px uten ærlig visuelt moment (section-kinds + bp-*-blokker teller; Band aldri).
5. **MEDIE-ÆRLIGHET** — capture-vs-drawing: ekte UI vises med ekte fangst; Artwork er akseptabelt gulv, aldri premium; gjenbrukte/tomstate-skjermbilder feiler (spreadsheet-wizards «No document is open»-frame er presedens).
6. **TINHOLT/QUAD** — den visuelle grammatikken holder i alle fire ruter (mørk + 390 inkludert).
7. **STEMME/EVIDENS** — kalibrerte rolleformuleringer intakte (registeret), ingen fabrikkasjonsmerker.

**To uavhengige dommere per innlegg. Forsoning: pessimistisk — enhver FAIL er FAIL** (deterministisk ved K=2, ordre-uavhengig, trenger ikke K=3). `numericConsensus` er BANNLYST for rubrikken: default band=25 flagger aldri contested på 1–5-skala (selv [1,5] passerer), og median-av-to runder opp hver 1-avstands-uenighet. Ratings-records er **top-level `ratings`-felt** på dommerens EGEN task (append-patch er låsfri, bevist); aldri delt paper (papers har ingen CLI-skrivevei; siste-skriver-vinner).

## Avgjørelser (Decide, 2026-08-02)
- **D1 Rubrikk**: kategorisk PASS/FAIL/NA + harde gulv, vedtatt over (numerisk bannlyst). Rubrikken er offentlig paper på jarl (søster til jarl-media-doctrine, menneskelig tittel).
- **D2 Kåring**: INTERNT på guerrilla. jarl-unlisted er motbevist (finnes ikke); offentlig kåring ville demotere navngitte klienter i sitemap+RSS og datere seg mot løftet.
- **D3 Rigg**: redning, ikke nybygg — kanoniser capture-jarl.mjs (+shoot.mjs-blob) inn i jarl-website med eager-force, cache-varming, full QUAD over alle 20 + vertikal-løp-probe som dekker sections-sider.
- **D4 Dommere**: 2 × alle 20, uavhengige, QUAD via CDP-oppskrift (ingen deps, bevist); records appendes til egen task.
- **D5 Tiering**: bunn seks = de seks null-seksjons-innleggene; media-nakne tre (polyflor-ordre, frick-design-system, doey) og bilde-bærende tre (hundesteder, aquatiq-synk, lunnheim) løftes i runde 2 denne bølgen. Story-tier er IKKE polish-only (svgloop/full-blast null media; spreadsheet-wizard gjenbrukt tomstate) → backlog ji-bl-story-media. Bunn-tilstøtende fire (galleryspace, oslobukta, kronprinsparets-fond, gyldendal) → backlog. Re-rate av alle 20 → backlog ji-bl-rerate-all (bølge 2) — budsjett-angrepet var reelt; én bølge bærer ikke hele buen med ærlige slices.
- **D6 Doktrine-duplikat**: `jarl-media-doctrine` (epic-sanksjonert, 48 blokker) overlever; `jarl-mediedoktrinen` (20 blokker, null proveniens) avpubliseres. Doktrinen rettes: 100×30, relative adresser.
- **D7 Hygiene**: 9 slug-som-tittel-papers får menneskelige titler (ren title-patch, ingen URL-endring); `order`-kollisjonene renummereres 1..20; de to tomme test-PNG-ene (proof-b, jarl-media-proof) slettes fra biblioteket.
- **D8 Oslobukta-spenningen** («tre år» på siden vs «fem år» i dossieret): FROSSET til eier-dom (ji-bl-oslobukta-owner-ruling). Dommere feller IKKE innlegget på denne; byggere rører INGEN av formuleringene. Den kalibrerte setningen «med omtrent hver tredje endring som min» står (65/174 ≈ hver tredje).
- **D9 Nye fangster**: ≥1920px brede kilder; caption-grammatikk per shipped praksis; cast-headere SKRUBBES (to live casts lekker absolutt scratchpad-sti — backlog ji-bl-cast-header-scrub for de eksisterende).
- **D10 Kvote**: media-kvoten er umålt; leses FØR runde 2-dispatch (står i løft-briefene).
- **D11 Ledger**: verify-radene (7 stk 2026-08-02) committes i charter-PR-en; pipeline+rigg kopieres fra flyktig /private/tmp inn i repoet som bølgens første handling (S1).
- **D12 Gates i aggregat**: `pnpm check` mangler check:sources og check:measure (CI har dem); aggregatet utvides i S1 så lokal grønn slutter å lyve.

## Bølgeplan (bølge 1 — task-ids på guerrilla, parent jarl-innleggene-epic)
Runde 1 (avhengighetsfri, bygges nå):
- `ji-w1-rig-pipeline-gates` (fable) — rigg + pipeline inn i repo, check-immovables.mjs + check-image-kilde.mjs, pnpm check-aggregat.
- `ji-w1-rubrikk-paper` (fable) — premium-rubrikken som offentlig paper på jarl.
- `ji-w1-judge-a` / `ji-w1-judge-b` (fable ×2) — uavhengig QUAD-dømming av alle 20.
- `ji-w1-corpus-hygiene` (opus) — doktrine-duplikat, titler, order, test-PNG-er.
Runde 2 (lead dispatcher etter merge/close av avhengigheter):
- `ji-w1-kaaring-reconcile` (fable, etter begge dommere) — pessimistisk forsoning + kåringspaper på guerrilla; beste innlegg kåres.
- `ji-w1-lift-media-naked` (fable, etter S1-merge + dommerne) — polyflor-ordre, frick-design-system, doey: repo-grunnede gjenoppbygg + ny ærlig media.
- `ji-w1-lift-bottom-rest` (fable, etter S1-merge + dommerne) — hundesteder, aquatiq-synk, lunnheim: substans/seksjons-løft (media finnes).
Backlog (filt, neste bølge): ji-bl-story-media, ji-bl-bottom-adjacent, ji-bl-rerate-all, ji-bl-oslobukta-owner-ruling, ji-bl-cast-header-scrub, ji-bl-prose-numeral-gate.

## Grenser
- Ingen deploy av jarl-website uten leads dom (innhold går live via ISR).
- Full Blast: ingen spillklipp (eierens egne); diagrammer/figurer er lov. **Gjelder også media hentet fra `frickin-real-time` til ticket-realtime.**
- doey-doctor-list.cast inneholder privat e-post: aldri publiser (finnes i scratchpad — skal aldri lastes opp).
- Prosaens fakta og kalibrerte roller flyttes ikke; registerets 23 strenger + negativraden er loven, i BEGGE lagre.
- Nye casts: header uten absolutte stier; nye fotokilder ≥1920px.
- Ratings-records forblir på guerrilla; kåringen publiseres aldri på jarl.
