# D5 rubric scores for all 100 wishlist candidates.
# Axes 1-5: d=demand evidence, f=frequency-of-use, u=unlock-power, r=cross-surface reach (honest per D2-D4).
# usefulness = .35d + .25f + .25u + .15r  (build cost = TIEBREAK ONLY, via D6/D7 tier)
# Flags: RESOLVER = blocked on aggregate/resolver plumbing (D10); SEAM = needs plugin
# block-registration seam (D10 backlog); D22 = binding dedup ruling caps the tier.
# Tier rule (stated in the paper): S = score >= 4.0 AND no unmet prerequisite flag;
# a flagged candidate caps at A regardless of score; D22 parity entries cap at C.
# Bands: A >= 3.4, B >= 2.7, C < 2.7.

FAM = {
    "dv": "data-viz & charts", "dg": "diagrams & technical", "ld": "live-data & task-ops",
    "ed": "editorial & structure", "ix": "interactive & disclosure", "me": "media",
    "geo": "geo & map", "dev": "dev & code", "fs": "fields & schema", "nav": "navigation & meta",
}

# id: (name, fam, code_tier, cost, d, f, u, r, flags, evidence)
S = {
 "B001": ("radial-dial","dv","widget","STATIC",3,3,3,4,"","D9 replacement mandate; no dial form on any surface; linear form owned by stat max-bar + gauge-list"),
 "B002": ("sparkline","dv","widget","STATIC",4,4,3,4,"","23 stat uses in the ledger embed sparks; the bare strip cannot be placed alone today"),
 "B003": ("bar-chart","dv","widget","STATIC",5,5,4,4,"","D9-mandated categorical form; gauge-list TUI prior art; passes D22 as the DISTINCT labeled ranking-bars block, not 'chart sideways'"),
 "B004": ("pie-chart","dv","widget","STATIC",4,4,3,4,"","D9-confirmed absent on every surface; mermaid pie kind proves terminal demand"),
 "B005": ("scatter-plot","dv","widget","STATIC",3,3,3,4,"","absent everywhere (D9); Observable chart-cell shows point-plot pull"),
 "B006": ("area-chart","dv","widget","STATIC",3,3,3,4,"","chart line series are the substrate; stacking is a distinct composition read"),
 "B007": ("histogram","dv","widget","STATIC",3,3,3,4,"","authors pre-chew bins into chart points by hand today"),
 "B008": ("box-plot","dv","widget","STATIC",2,2,3,4,"","narrow: benchmark/latency docs only; averages hide outliers is the pitch, not a cited demand"),
 "B009": ("waterfall-chart","dv","widget","STATIC",3,2,3,4,"","cost stories exist (token-cost meter docs) but hand-drawn rarely"),
 "B010": ("funnel-chart","dv","widget","STATIC",3,2,3,4,"","Cloud console + onboarding docs describe funnels in prose"),
 "B011": ("radar-chart","dv","widget","STATIC",3,2,3,4,"","Cody 14-dimension grades are a real recurring consumer"),
 "B012": ("treemap","dv","widget","STATIC",3,2,3,4,"","hierarchical share (disk, census) has no home block"),
 "B013": ("sankey","dv","widget","STATIC",2,2,4,4,"","high wow, thin cited demand; layout is the honest hard part"),
 "B014": ("calendar-heatmap","dv","widget","STATIC",3,3,3,4,"","heatmap is not date-aware; activity-by-day needs hand-sliced weeks today"),
 "B015": ("scientific-plot","dv","widget","STATIC",3,2,4,4,"","Typst gap; engineering notes ship screenshots today"),
 "B016": ("chart-cell","dv","widget","I1",3,3,5,3,"RESOLVER","Observable's flagship pull; reactive-doc gateway"),
 "B017": ("data-grid","dv","widget","I1",4,4,4,3,"RESOLVER","207 hand-typed tables in the ledger show tabular appetite"),
 "B018": ("diagram-gantt-tui","dg","element","STATIC",3,3,2,2,"D22","browser already renders all mermaid kinds; TUI gap only"),
 "B019": ("diagram-er-tui","dg","element","STATIC",3,3,2,2,"D22","browser already renders all mermaid kinds; TUI gap only"),
 "B020": ("diagram-class-tui","dg","element","STATIC",3,3,2,2,"D22","browser already renders all mermaid kinds; TUI gap only"),
 "B021": ("diagram-pie-tui","dg","element","STATIC",3,3,2,2,"D22","browser already renders all mermaid kinds; TUI gap only"),
 "B022": ("diagram-gitgraph-tui","dg","element","STATIC",3,3,2,2,"D22","browser already renders all mermaid kinds; TUI gap only"),
 "B023": ("diagram-state-tui","dg","element","STATIC",3,3,2,2,"D22","browser already renders all mermaid kinds; TUI gap only"),
 "B024": ("diagram-journey-tui","dg","element","STATIC",3,3,2,2,"D22","browser already renders all mermaid kinds; TUI gap only"),
 "B025": ("equation","dg","element","STATIC",5,4,5,4,"","confirmed Notion AND Typst gap; TeX->MathML is zero-JS native; unlocks a whole document class"),
 "B026": ("vector-diagram","dg","widget","STATIC",3,2,4,4,"","Typst gap; mermaid's opinionated layouts refuse annotated-coordinate diagrams"),
 "B027": ("tree-diagram","dg","widget","STATIC",3,3,3,4,"","Typst gap; filetree draws paths only; mermaid fakes read badly in TUI"),
 "B028": ("chemfig","dg","element","STATIC",1,1,2,3,"","wishlist itself expects a low rank; completeness entry for the Typst survey"),
 "B029": ("timeline-gantt","ld","widget","STATIC",4,3,4,3,"RESOLVER","Projects Board shipped a bespoke Gantt - demand AND renderer proven; rows lack date spans"),
 "B030": ("burndown-chart","ld","widget","STATIC",3,3,4,3,"","agg path already supports count + over(closed_at) buckets; nearly free"),
 "B031": ("task-calendar","ld","widget","STATIC",3,3,3,3,"RESOLVER","planning read boards do not give; needs date fields in row shape"),
 "B032": ("activity-feed","ld","widget","STATIC",4,3,4,3,"RESOLVER","the 'is this epic alive?' read the ledger-liveness doctrine keeps asking for; no event source exposed"),
 "B033": ("claim-monitor","ld","widget","STATIC",3,3,4,3,"RESOLVER","pulse now-line contract has no reader surface; claim fields not in row shape"),
 "B034": ("criteria-progress","ld","widget","STATIC",4,4,4,4,"","resolver rows ALREADY carry criteria - pure shaping job; wave papers hand-write met/total counts constantly"),
 "B035": ("epic-heartbeat","ld","widget","STATIC",4,3,4,3,"RESOLVER","charter contract writes wave_status every phase; nothing renders it; passthrough missing"),
 "B036": ("countdown","ld","widget","I1",2,3,2,3,"","niche; honest absolute-date degrade is the whole design"),
 "B037": ("deploy-status","ld","widget","STATIC",3,2,4,3,"SEAM","runbooks that show the truth they describe; plugin-domain data"),
 "B038": ("sheet-chart","ld","widget","STATIC",3,3,4,3,"SEAM","Sheets plugin owns real maintained tabular data; closes the copy-paste loop"),
 "B039": ("paper-stats","ld","widget","STATIC",3,2,3,3,"RESOLVER","the census grounding the wishlist was hand-run SQL; content-source aggregate needed"),
 "B040": ("footnote","ed","widget","STATIC",4,4,4,5,"","long-form papers fake references with parenthetical asides; REAL email render"),
 "B041": ("sidenote","ed","widget","STATIC",3,3,3,5,"","Tufte margin note; the honest-degrade story is the design"),
 "B042": ("glossary-term","ed","widget","I0",3,4,3,5,"","Barkpark's own papers are jargon-dense (E-grades, I-tiers, seams); native details"),
 "B043": ("steps","ed","widget","STATIC",5,5,4,5,"","GitBook AND ReadMe ship it; runbooks here hand-number headings and lose semantics; REAL email render"),
 "B044": ("faq","ed","widget","I0",4,4,3,5,"","tickets plugin is a real consumer; support/launch pages want the shape"),
 "B045": ("definition-list","ed","widget","STATIC",4,4,3,5,"","many of the 207 ledger tables are two-column definition tables in disguise"),
 "B046": ("chronology","ed","widget","STATIC",3,3,3,5,"","postmortems/history docs; distinct from live timeline-gantt (hand-authored narrative)"),
 "B047": ("changelog","ed","widget","STATIC",4,4,3,5,"","every SDK release note is hand-formatted headings + lists today"),
 "B048": ("citation-list","ed","widget","STATIC",3,2,3,5,"","perfect-plan verdict papers cite bare URLs; Typst pull"),
 "B049": ("pros-cons","ed","widget","STATIC",3,4,3,5,"","decision docs hand-roll columns + callouts for this"),
 "B050": ("hero","ed","widget","STATIC",4,3,4,4,"","content-first doctrine gives title+featured-image; launch/template pages need the composed front door"),
 "B051": ("page-break","ed","element","STATIC",2,2,2,2,"","paper-to-PDF path has no pagination control; narrow"),
 "B052": ("tabs","ix","section","I1",5,4,4,4,"","prior art IN the repo (dashboard.go {label,blocks}); GitBook ships it; per-OS installs need it"),
 "B053": ("expandable","ix","widget","I0",4,5,3,5,"","D9 repriced onto callout's SHIPPED native-details pattern (walk.ex:1415-1434); GitBook's block by name"),
 "B054": ("toggle-list","ix","widget","I0",4,4,3,5,"","Notion/Craft day-one outline expectation; per-item details"),
 "B055": ("carousel","ix","section","I1",3,3,3,3,"","product tours; stacked degrade stays honest"),
 "B056": ("action-button","ix","widget","I2",4,3,5,3,"","Coda pull; FIRST write-path block - security surface IS the cost"),
 "B057": ("template-button","ix","widget","I2",3,3,3,2,"","Notion template button; Studio-edit-only by nature"),
 "B058": ("reactive-input","ix","widget","I2",3,3,5,3,"","Observable's core move; biggest unlock in family, honestly the most expensive (client dataflow graph)"),
 "B059": ("poll","ix","widget","I2",3,3,3,3,"","team decisions/talk feedback; needs per-principal dedup"),
 "B060": ("checklist","ix","widget","I2",4,4,4,3,"","onboarding + runbook progress that survives reload; reader+doc state"),
 "B061": ("quiz-embed","ix","widget","I2",4,3,4,3,"SEAM","Hyperquiz is LIVE as Plugins.Quiz on this instance; papers cannot host it"),
 "B062": ("video","me","element","STATIC",5,4,4,3,"","census: ZERO video blocks in 294 papers BECAUSE no block exists; product demos want it"),
 "B063": ("audio","me","element","STATIC",3,2,3,3,"","voice notes/podcast clips; transcript doubles as degrade"),
 "B064": ("gallery","me","widget","I0/I1",4,4,3,4,"","screenshot-heavy release notes stack figures vertically today; grid is I0, lightbox I1"),
 "B065": ("image-compare","me","widget","I1",3,3,3,3,"","view-edit-parity audits ship side-by-side screenshots that beg for it"),
 "B066": ("pdf-embed","me","element","STATIC",3,3,3,3,"","contracts/specs live as PDFs and leave the paper today"),
 "B067": ("file-attachment","me","element","STATIC",4,4,3,5,"","media plugin stores files; papers cannot hand one to the reader; a link is a link in email (REAL)"),
 "B068": ("svg-inline","me","element","STATIC",3,3,3,3,"","design-tool exports; the sanitizer IS the feature - XSS hole without it (honest security cost)"),
 "B069": ("icon","me","element","STATIC",3,4,2,4,"","Lucide already bundled in Studio; status glyphs without image round-trips"),
 "B070": ("map","geo","widget","I1",5,3,4,3,"","strongest dedup-by-demand: SAME dep-free Canvas2D map duplicated in web/listings-map.tsx AND hundesteder/places-map.tsx - one block retires two forks"),
 "B071": ("map-route","geo","widget","I1",3,2,3,3,"","hundesteder domain is literally routes and places"),
 "B072": ("choropleth","geo","widget","I1",2,2,3,3,"","big geometry payloads; block must own simplification discipline"),
 "B073": ("location-card","geo","widget","I1",3,3,3,3,"","hundesteder place-page pattern as a reusable block"),
 "B074": ("geojson-map","geo","widget","I1",2,2,3,3,"","power-user escape hatch; narrow"),
 "B075": ("api-endpoint","dev","widget","STATIC",5,4,4,5,"","docs/api-v1.md hand-formats DOZENS of endpoint cards today; docs-platform staple; REAL email render"),
 "B076": ("openapi-console","dev","widget","I2",3,2,5,2,"","docs/openapi.json is maintained; try-it console makes it executable; heavy I2"),
 "B077": ("code-tabs","dev","widget","I1",5,5,4,3,"","SDK docs across Go/JS/HTTP need it on nearly every page; synced switcher"),
 "B078": ("json-viewer","dev","widget","I0",4,4,3,5,"","capabilities manifest + task docs are exactly this shape; native details per node"),
 "B079": ("csv-table","dev","element","STATIC",4,4,3,5,"","removes hand-conversion behind many of the 207 ledger tables"),
 "B080": ("commit-card","dev","widget","STATIC",3,3,3,4,"SEAM","postmortems cite bare hashes; github plugin owns the data (source EXACTLY 'github')"),
 "B081": ("pr-status","dev","widget","STATIC",4,3,4,4,"SEAM","wave papers narrate PRs by number and go stale the moment a gate flips"),
 "B082": ("kbd","dev","element","STATIC",4,4,2,5,"","keybindings guide + TUI docs describe chords in prose; every docs platform renders caps"),
 "B083": ("badge-row","dev","element","STATIC",3,3,2,5,"","READMEs get shields.io, papers get nothing; no external image dependency"),
 "B084": ("package-install","dev","widget","I1",4,4,3,3,"","first block of every SDK quickstart; syncs with code-tabs syncKey"),
 "B085": ("field-number","fs","element","STATIC+SE",5,4,4,3,"","the MISSING numeric atom - string/slug/text/boolean/select/datetime/color/image/reference exist, number does not; every schema with a price/count/weight hits this wall FIRST"),
 "B086": ("field-url","fs","element","STATIC+SE",3,3,3,3,"","validation + link-preview affordance; pairs with shipped OG manifest"),
 "B087": ("field-file","fs","element","STATIC+SE",3,3,3,3,"","schemas model downloads with a string-URL hack today"),
 "B088": ("field-geopoint","fs","element","STATIC+SE",3,2,3,3,"","hundesteder stores coordinates as two bare floats with no picker"),
 "B089": ("field-json","fs","element","STATIC+SE",3,3,3,3,"","escape hatch for structured config values"),
 "B090": ("field-rating","fs","element","STATIC+SE",3,3,3,3,"","reviews, quiz scoring, graded dimensions as schema data"),
 "B091": ("field-tags","fs","element","STATIC+SE",4,3,4,3,"","Barkpark's OWN weighted-tag contract has no control; every publish wall runs on hand-typed JSON"),
 "B092": ("schema-card","fs","widget","STATIC",4,3,4,4,"RESOLVER","SDK/API docs re-type schemas by hand and drift from source of truth; needs schema-source resolver"),
 "B093": ("toc","nav","widget","STATIC",5,5,4,5,"","confirmed Notion gap, GitBook standard, painfully absent from the 500-block wishlist paper ITSELF; server-walked, zero JS, REAL email render"),
 "B094": ("breadcrumb","nav","widget","STATIC",3,3,3,4,"RESOLVER","Notion gap; needs doc-graph ancestors exposed to blocks"),
 "B095": ("backlinks","nav","widget","STATIC",4,3,4,4,"RESOLVER","reverse_referencers capability EXISTS server-side with no block surfacing it"),
 "B096": ("related-papers","nav","widget","STATIC",3,3,3,4,"RESOLVER","weighted-tag similarity signal nothing reads yet; needs content-query resolver"),
 "B097": ("synced-block","nav","widget","I2",3,3,4,3,"","embed covers whole-note transclusion; consistency semantics are the hard 80% (honest)"),
 "B098": ("link-preview","nav","widget","STATIC",4,4,3,5,"","machinery ALREADY shipped: OG preview manifest (preview-contract, no-oEmbed law); fetch at save, render static"),
 "B099": ("paper-list","nav","widget","STATIC",4,4,4,4,"RESOLVER","index pages and team homepages hand-curate link lists that go stale weekly; scores 4.00 but capped A by the resolver prerequisite"),
 "B100": ("freshness-badge","nav","widget","STATIC",3,3,4,5,"","Slite's verification badge; makes doc-rot a visible, gateable state (distrust-vacuous-green, applied to prose)"),
}

def score(v):
    _,_,_,_,d,f,u,r,_,_ = v
    return round(.35*d + .25*f + .25*u + .15*r, 2)

def tier(bid, v):
    s = score(v)
    flags = v[8]
    if "D22" in flags: return "C"
    if s >= 4.0 and not flags: return "S"
    if s >= 3.4 or (s >= 4.0 and flags): return "A"
    if s >= 2.7: return "B"
    return "C"

if __name__ == "__main__":
    from collections import Counter
    tiers = {b: tier(b, v) for b, v in S.items()}
    print(Counter(tiers.values()))
    assert len(S) == 100
    st = [b for b, t in tiers.items() if t == "S"]
    print(len(st), st)
