# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-08-24
- Primary product surfaces: Public Paper reader, Barkpark Chronicle index, Chronicle day/week/month/year editions, Studio Paper editor, email and TUI Paper views.
- Evidence reviewed: `api/assets/paper-surface/paper-surface.css`, `api/lib/barkpark_web/controllers/scoped_paper_html/show.html.heex`, `tooling/paper-excellence/rig/README.md`, the committed Paper Excellence screenshot panel, and a fresh eight-viewport render of `barkpark-chronicle`.

## Brand
- Personality: Precise, calm, crafted, optimistic, and technically credible.
- Trust signals: Plain-language release notes, dates, stable source links, transparent provenance, and consistent edition hierarchy.
- Avoid: Internal build jargon in primary copy, dashboard-like density, ornamental gradients, generic SaaS card walls, fake urgency, and metrics without a reader job.

## Product goals
- Goals: Make Barkpark shipping activity easy to scan, understand, browse, and trust; make every edition feel like a considered review of the period rather than generated Git output; give project managers, stakeholders, investors, contributors, and curious readers a shared understanding of momentum.
- Non-goals: Marketing landing pages, raw commit mirrors, release-volume leaderboards, or a new Paper design system.
- Success signals: A non-technical first-time reader can answer “What did Barkpark work on?” in under thirty seconds, identify the newest release, choose a day/week/month/year view, and reach source evidence without instruction. On the Chronicle index, one latest story is visually dominant and one calm navigation choice follows it; no competing card or button obscures that path.

## Personas and jobs
- Primary personas: Project managers tracking movement and risk; stakeholders and investors judging direction and momentum; Barkpark users following product progress; contributors checking what landed; operators auditing a release period.
- User jobs: Understand the period's story without knowing the codebase, see the few themes that materially moved forward, judge the period honestly, browse prior releases, inspect evidence when wanted, and share a stable edition URL.
- Key contexts of use: Desktop reading, mobile scanning, linked release announcements, Studio editing, terminal/email parity.

## Information architecture
- Primary navigation: Chronicle index → current day/week/month/year editions → adjacent editions and source evidence.
- Core routes/screens: `/papers/barkpark-chronicle`, `/papers/barkpark-changelog-YYYY-MM-DD`, `/papers/barkpark-changelog-YYYY-wWW`, `/papers/barkpark-changelog-YYYY-MM`, `/papers/barkpark-changelog-YYYY`.
- Content hierarchy: Branded edition → plain-English answer to “What did we work on?” → at most three work themes → one progress assessment → collapsed technical record and archive.

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
- Tradeoffs: Editorial clarity outranks exhaustive detail above the fold; exhaustive ledgers remain available lower in each edition.

## Visual language
- Color: Existing evergreen Paper palette; semantic accents only for release categories and status.
- Typography: Existing Paper editorial serif for narrative hierarchy and system sans/mono for metadata, labels, and evidence.
- Spacing/layout rhythm: Preserve the measured 660px prose column, wide evidence band, 92px section beat, and structural rule hierarchy. The index uses no authored divider immediately before a section heading and no one-item grid; its open editorial groups should feel like a journal contents page, not stacked containers.
- Shape/radius/elevation: Existing restrained Paper cards; no new shadows or decorative chrome.
- Motion: None required for reading; existing theme controls only.
- Imagery/iconography: Product screenshots may be added when real assets exist; do not invent decorative imagery. Use terse text labels rather than icon clutter.

## Components
- Existing components to reuse: Eyebrow, heading, ingress, byline, columns, stats, section/grid, slot-based card with action, chart, lineage, list, callout, divider, expandable, and inline link.
- New/changed components: No renderer component required. Chronicle editions use a short plain-English opening, up to three source-linked work-theme cards, one progress-assessment callout, and one expandable technical record. The Chronicle index uses an unboxed latest-story treatment, borderless two-column edition navigation, a plain monthly list, and one expandable shipping record. Reading links stay inline; large button actions are reserved for workflows rather than editorial navigation.
- Variants and states: Day/week/month/year cards use distinct labels, not arbitrary colors; empty periods receive an explicit quiet-edition message and retain navigation.
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
- Loading: Server-rendered Paper body remains meaningful before enhancement.
- Empty: Quiet editions state that no mainline changes landed and still link to adjacent periods.
- Error: Publish failures name the exact slug and HTTP response; no partially successful batch is reported as complete.
- Success: The index publishes last, after all editions, and becomes the stable confirmation surface.
- Disabled: Not applicable to the read-only Chronicle.
- Offline/slow network: Core text and links are server-rendered; no remote media is required for the reading path.

## Content voice
- Tone: Clear, warm, specific, and lightly playful; closer to a beautifully edited product journal than an engineering report. Confident about shipped facts, restrained about interpretation, and comfortable saying that a period was mostly maintenance.
- Terminology: Prefer ordinary phrases such as “clearer errors,” “more complete results,” “safer access,” and “easier day-to-day use.” Reserve counts, internal component names, code paths, protocols, fields, flags, commit language, “first-parent,” “digest,” and “renderer” for the technical record.
- Microcopy rules: Answer “What changed?” in the headline and “why would I notice?” in the opening; use sentence case; keep navigation labels under five words; use short sentences; group related changes into concrete product movements; never expose a commit subject as the page's primary promise; never require the reader to translate implementation mechanics; use “we” only for grounded editorial interpretation. Headlines use a named subject plus a specific change or outcome, with enough room to name two closely related changes when that is the honest story. Reject mood-only or abstract-result titles such as “Opening new possibilities,” “Useful progress,” “Making work smoother,” “Building momentum,” “Polishing the experience,” or “Chronicle editions gain distinct identity.”
- Main-path language gate: Above the technical record, reject code identifiers, acronyms, endpoints, protocol names, internal product components, and implementation terms such as pagination, allowlists, callbacks, schemas, request IDs, read paths, rollout latches, and retry mechanics.

## Editorial system
- Edition contract: `theme`, `plain_summary`, one-to-three `work_themes` with `explanation`, `outcome`, and source references, plus one `progress_assessment`.
- Scale: Daily editions say plainly what kind of day it was and what changed; weekly editions connect work into a direction; monthly editions explain the durable themes; annual editions describe the larger arc. Longer periods do not earn more primary sections—only stronger synthesis.
- Authorship: An AI editorial pass may synthesize the verified event packet. It receives bounded source records and aggregate facts, returns strict structured JSON, and is rejected unless every work theme cites supplied commit identifiers, every headline passes the subject-plus-change gate, and all visible copy passes the main-path language gate.
- Grounding: Numeric facts are rendered deterministically outside model prose. Model prose must not introduce numbers, customer claims, financial claims, adoption claims, security guarantees, dates, deadlines, or unshipped promises.
- Fallback: If editorial generation is unavailable or invalid, every edition still receives the same narrative sections from a deterministic, source-grounded editor. Generation and publishing fail soft; evidence never disappears.
- Freshness: The scheduled publisher generates editorial copy only for the current day, week, month, and year. Historical editions remain stable at their last published review; full-history generation remains available for verification and deliberate backfills.
- Reader trust: The progress assessment distinguishes feature work, reliability work, and quiet periods without spin. The complete programmatic record remains inside one clearly labeled expandable section below the editorial layer.

## Implementation constraints
- Framework/styling system: Phoenix/LiveView public reader with PortableDoc block composition and the canonical Paper stylesheet.
- Design-token constraints: Reuse existing generated tokens and Paper component CSS; no new token family for Chronicle MVP.
- Performance constraints: One Git history scan; one bounded editorial request for the current edition family; bounded publish concurrency; no client-side data dependency for core content.
- Compatibility constraints: Generated blocks must render in reader, Studio, email, and TUI; stable Paper URLs and source documents remain deterministic.
- Test/screenshot expectations: Generator tests, structure/quality audit, design checks, and hermetic light/dark screenshots at 360/768/1280/1920.

## Open questions
- [ ] Decide whether future product screenshots should be captured automatically per release or curated manually / product owner / affects media-rich release cards.
- [ ] Decide whether literally quiet calendar days deserve public editions or only navigation placeholders / product owner / affects archive completeness and volume.
- [ ] Decide whether a human editor should be able to lock or amend an AI-written review without losing automatic source updates / product owner / affects protected editorial overlays.
