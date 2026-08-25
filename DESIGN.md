# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-08-25
- Primary product surfaces: Public Paper reader, Barkpark Chronicle index, Chronicle day/week/month/year editions, Studio Paper editor, email and TUI Paper views.
- Evidence reviewed: `api/assets/paper-surface/paper-surface.css`, the PortableDoc image/figure/asciicast renderers, the live Paper relation resolver, `docs/evidence/**`, `tooling/paper-excellence/evidence/**`, the committed Paper Excellence screenshot panel, and fresh multi-viewport Chronicle renders.

## Brand
- Personality: Precise, calm, crafted, optimistic, and technically credible.
- Trust signals: Plain-language release notes, dates, stable source links, transparent provenance, and consistent edition hierarchy.
- Avoid: Internal build jargon in primary copy, dashboard-like density, ornamental gradients, generic SaaS card walls, fake urgency, and metrics without a reader job.

## Product goals
- Goals: Make Barkpark shipping activity easy to scan, understand, browse, and trust; make every edition feel like a considered review of the period rather than generated Git output; give project managers, stakeholders, investors, contributors, and curious readers a shared understanding of momentum.
- Non-goals: Marketing landing pages, raw commit mirrors, release-volume leaderboards, or a new Paper design system.
- Success signals: A non-technical first-time reader can answer “What did Barkpark work on?” in under thirty seconds, see a real example of the change when one exists, choose any calendar day/week/month/year, open a genuinely relevant Paper, and reach source evidence without instruction.

## Personas and jobs
- Primary personas: Project managers tracking movement and risk; stakeholders and investors judging direction and momentum; Barkpark users following product progress; contributors checking what landed; operators auditing a release period.
- User jobs: Understand the period's story without knowing the codebase, see the few themes that materially moved forward, judge the period honestly, browse prior releases, inspect evidence when wanted, and share a stable edition URL.
- Key contexts of use: Desktop reading, mobile scanning, linked release announcements, Studio editing, terminal/email parity.

## Information architecture
- Primary navigation: Chronicle index → current day/week/month/year editions → adjacent editions and source evidence.
- Core routes/screens: `/papers/barkpark-chronicle`, `/papers/barkpark-changelog-YYYY-MM-DD`, `/papers/barkpark-changelog-YYYY-wWW`, `/papers/barkpark-changelog-YYYY-MM`, `/papers/barkpark-changelog-YYYY`.
- Content hierarchy: Branded edition → plain-English answer → visible period pulse → real visual overture when available → defining work themes → progress assessment → release highlights → period chapters and related Papers → collapsed complete ledger.

## Design principles
- Lead with reader value: Describe the shipped outcome before its repository mechanics.
- Review, do not transcribe: Synthesize the period into a defensible point of view; counts and commit subjects are evidence, not the story.
- Headline the change, not the mood: Every edition earns a short news headline that names the product, surface, or capability that moved and says what happened. A title must carry enough factual meaning to distinguish this edition from another one before the body is read.
- One story for everyone: Explain the work in ordinary language that a colleague, customer, or curious reader can share; do not repeat it through separate audience lenses.
- Details are the backbone, not the face: Keep counts, categories, commit subjects, charts, and provenance complete but collapsed below the editorial reading path.
- Lightness through restraint: Let one warm turn of phrase or moment of personality carry the edition; avoid both corporate solemnity and forced jokes.
- Be candid about uncertainty: Separate shipped facts from interpretation, risks, and future signals. Never invent customers, revenue, adoption, deadlines, or promises.
- Familiar at first glance: Use recognizable changelog conventions—release date, category, highlight, details, archive, source.
- Evidence without noise: Keep Git provenance available and explicit, but subordinate it to the product story.
- One premium system: Compose existing Paper blocks and tokens; improve Chronicle authorship rather than forking the renderer.
- Scale earns scope: A day is a crisp dispatch, a week is a review, a month is a visual magazine issue, and a year is an annual. Longer periods use more chapters and real evidence without turning the main path into a raw ledger.
- Newspaper × time machine: A long edition behaves like a front page with a point of view and a calendar with memory. It leads with the strongest verified conclusion, lets readers travel to the day or week that shaped it, and makes compounding work visible through explicitly labelled relationships.
- Unequal stories, equal truth: Editorial importance controls visual scale. One lead may dominate a spread while supporting chapters stay compact, but every story follows the same evidence, sourcing, and plain-language rules.
- Tradeoffs: Editorial clarity outranks exhaustive detail above the fold; exhaustive ledgers remain available lower in each edition.

## Visual language
- Color: Existing evergreen Paper palette; semantic accents only for release categories and status.
- Typography: Existing Paper editorial serif for narrative hierarchy and system sans/mono for metadata, labels, and evidence.
- Spacing/layout rhythm: Preserve the measured 660px prose column for every Paper, including month and year editions; period scale must never widen the main shell. Figures, time rails, relationship maps, tables, stats, charts, and deliberate column compositions may use the shared evidence breakout band when their content benefits from width. A breakout is a local composition, not a new page container: the blocks before and after it return to the 660px reading line. Preserve the 92px section beat and structural rule hierarchy. A monthly or annual visual overture pairs editorial context with one focused lead artifact inside the native column system; it never drops a full-page screenshot across the entire evidence band. The issue rhythm is masthead → asymmetric lead → thirty-second brief → time rail → unequal story spread → relationship thread → deeper record. The index uses no authored divider immediately before a section heading and no one-item grid; its open editorial groups should feel like a journal contents page, not stacked containers.
- Shape/radius/elevation: Existing restrained Paper cards; no new shadows or decorative chrome.
- Motion: None required for reading; existing theme controls only.
- Imagery/iconography: Screenshots and asciicasts are evidence, never decoration. Each artifact must come from a commit inside the edition, explain what the reader is seeing, and be omitted when no honest visual exists. Prefer one representative over light/dark/mobile duplicates. Reject full-document reader captures, screenshot-rig baselines, and repeated artifacts from one release when a focused product view exists. Longer editions compose a restrained lead plus a small proof gallery; honest scarcity is more premium than filler. Never autoplay.

## Components
- Existing components to reuse: Eyebrow, heading, ingress, byline, columns, stats, section/grid, slot-based card with action, chart, lineage, list, callout, divider, expandable, and inline link.
- New/changed components: Chronicle composes native `stats`, `columns`, `figure(image)`, `asciicast`, `diagram`, `bar-chart`, `section`, `card`, `lineage`, and `expandable` blocks into a masthead, lead package, thirty-second brief, calendar rail, unequal story spread, relationship thread, and deeper record. The rail is deterministic: density comes from shipped events and named stops come from source-linked editorial milestones. Relationship edges carry verbs such as “made reusable” or “applied”; an unlabeled arrow is not sufficient evidence of causality. A `paper-links` block carries authored Paper refs and editorial reasons for both related reading and calendar chapters; the reader resolves current published details while email/TUI retain honest authored links. Month and year calendars use its `chapters` layout: a two-column evidence-band spread with a unique, source-grounded headline and short reader outcome for every chapter. Change volume is supporting metadata, never the headline or summary, and repeated generated headlines are a regression. The index keeps an unboxed latest story, borderless edition navigation, a monthly list, and one expandable complete calendar.
- Variants and states: Day uses at most one screenshot and one cast; week three and one; month four and two; year six and two. These are ceilings, not quotas. Month and year keep every figure inside a contained native column or grid composition, use varied story spans rather than equal card walls, and use live Paper links for week/month chapters. Missing honest media degrades to a deterministic data graphic, diagram, or text—not a stock image or recycled screenshot. Empty periods receive an explicit quiet-edition message and retain navigation.
- Token/component ownership: `design/tokens.json` and `api/assets/paper-surface/paper-surface.css` remain canonical; Chronicle-specific composition lives in `scripts/chronicle-paper.py`.

## Accessibility
- Target standard: WCAG 2.2 AA.
- Keyboard/focus behavior: Every edition action is a semantic link with visible native focus treatment; reading order matches DOM order.
- Contrast/readability: Preserve existing tested Paper tokens, editorial line measure, and theme parity.
- Screen-reader semantics: One h1, ordered heading levels, meaningful action labels, descriptive link text, no meaning conveyed by color alone.
- Reduced motion and sensory considerations: No Chronicle-specific animation; charts retain textual values.

## Responsive behavior
- Supported breakpoints/devices: Existing Paper rig at 360, 768, 1280, and 1920 pixels in light and dark themes.
- Layout adaptations: Linked card grids collapse to one track on narrow screens; evidence components stay within the measured breakout band; prose measure remains unchanged.
- Touch/hover differences: Actions remain fully legible without hover and meet the renderer's existing tap-target behavior.

## Interaction states
- Loading: Server-rendered Paper body and authored related-Paper fallbacks remain meaningful before live detail resolution.
- Empty: Quiet editions state that no mainline changes landed and still link to adjacent periods.
- Error: Publish failures name the exact slug and HTTP response; no partially successful batch is reported as complete.
- Success: The index publishes last, after all editions, and becomes the stable confirmation surface.
- Disabled: Not applicable to the read-only Chronicle.
- Offline/slow network: Core text and links are server-rendered. Media is optional evidence, and related cards preserve their authored links when live resolution is unavailable.

## Content voice
- Tone: Clear, warm, specific, and lightly playful; closer to a beautifully edited product journal than an engineering report. Confident about shipped facts, restrained about interpretation, and comfortable saying that a period was mostly maintenance.
- Terminology: Prefer ordinary phrases such as “clearer errors,” “more complete results,” “safer access,” and “easier day-to-day use.” Reserve counts, internal component names, code paths, protocols, fields, flags, commit language, “first-parent,” “digest,” and “renderer” for the technical record.
- Microcopy rules: Answer “What changed?” in the headline and “why would I notice?” in the opening; use sentence case; keep navigation labels under five words; use short sentences; group related changes into concrete product movements; never expose a commit subject as the page's primary promise; never require the reader to translate implementation mechanics; use “we” only for grounded editorial interpretation. Headlines use a named subject plus a specific change or outcome, with enough room to name two closely related changes when that is the honest story. Reject mood-only or abstract-result titles such as “Opening new possibilities,” “Useful progress,” “Making work smoother,” “Building momentum,” “Polishing the experience,” or “Chronicle editions gain distinct identity.”
- Scan-depth contract: The lead headline and opening answer the month in one breath; the thirty-second brief names three observable outcomes; chapter intros explain the work in ordinary language; source groups and technical mechanics remain one deliberate action deeper. A reader never has to choose between blandness and raw implementation detail.
- Main-path language gate: Above the technical record, reject code identifiers, acronyms, endpoints, protocol names, internal product components, and implementation terms such as pagination, allowlists, callbacks, schemas, request IDs, read paths, rollout latches, and retry mechanics.

## Editorial system
- Edition contract: `theme`, `plain_summary`, one-to-three `work_themes` with `explanation`, `outcome`, and source references, plus one `progress_assessment`.
- Scale: Daily editions say plainly what kind of day it was and what changed; weekly editions connect work into a direction; monthly editions become richly illustrated issues that explain durable themes and the weeks inside them; annual editions become visual records of the larger arc. The extra depth must remain authored, scannable, and grounded rather than repeating the source ledger.
- Authorship: An AI editorial pass may synthesize the verified event packet. It receives bounded source records and aggregate facts, returns strict structured JSON, and is rejected unless every work theme cites supplied commit identifiers, every headline passes the subject-plus-change gate, and all visible copy passes the main-path language gate.
- Grounding: Numeric facts are rendered deterministically outside model prose. Model prose must not introduce numbers, customer claims, financial claims, adoption claims, security guarantees, dates, deadlines, or unshipped promises.
- Relationships: Editorial synthesis may connect changes only with a bounded, reviewable relationship vocabulary: `continued`, `exposed`, `made reusable`, `made verifiable`, `applied`, and `followed by`. Stronger dependency or causal claims require a cited source that states the dependency. Every relationship node resolves to an edition or source group.
- Fallback: If editorial generation is unavailable or invalid, every edition still receives the same narrative sections from a deterministic, source-grounded editor. Generation and publishing fail soft; evidence never disappears.
- Freshness: Scheduled publishing generates the complete calendar, updates the current family and index, creates missing historical editions, and preserves existing historical reviews. Deliberate full-archive editorial runs may refresh all active editions.
- Reader trust: The progress assessment distinguishes feature work, reliability work, and quiet periods without spin. The complete programmatic record remains inside one clearly labeled expandable section below the editorial layer.

## Implementation constraints
- Framework/styling system: Phoenix/LiveView public reader with PortableDoc block composition and the canonical Paper stylesheet.
- Design-token constraints: Reuse existing generated tokens and Paper component CSS; no new token family for Chronicle MVP.
- Performance constraints: One Git history scan including changed paths; bounded editorial batches; bounded publish concurrency; batched related-Paper resolution; no client-side dependency for core content.
- Compatibility constraints: Generated blocks must render in reader, Studio, email, and TUI; stable Paper URLs and source documents remain deterministic.
- Test/screenshot expectations: Generator tests, structure/quality audit, design checks, and hermetic light/dark screenshots at 360/768/1280/1920. The primary 1440 × 1200 capture must pass a five-second comprehension test (edition, factual lead, consequence, authentic proof, and the start of the brief are visible), the monthly rail must expose every active day plus source-linked milestone travel, and at least one labelled relationship thread must connect three or more source-grounded changes. A structured visual verdict must score at least 90/100; truth, width leakage, overflow, accessibility, or five-second comprehension failures remain blocking regardless of aggregate score.

## Open questions
- [ ] Decide whether a human editor should be able to lock or amend an AI-written review without losing automatic source updates / product owner / affects protected editorial overlays.
- [ ] Decide which product moments deserve a deliberately recorded cast when no committed recording exists / product owner / affects future media coverage, never archive completeness.
