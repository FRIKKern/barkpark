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
- Success signals: A first-time reader can identify the newest release, understand what changed, choose a day/week/month/year view, and reach source evidence without instruction.

## Personas and jobs
- Primary personas: Project managers tracking movement and risk; stakeholders and investors judging direction and momentum; Barkpark users following product progress; contributors checking what landed; operators auditing a release period.
- User jobs: Understand the period's story, see what materially moved forward, judge why it matters, identify uncertainty, browse prior releases, inspect evidence, and share a stable edition URL.
- Key contexts of use: Desktop reading, mobile scanning, linked release announcements, Studio editing, terminal/email parity.

## Information architecture
- Primary navigation: Chronicle index → current day/week/month/year editions → adjacent editions and source evidence.
- Core routes/screens: `/papers/barkpark-chronicle`, `/papers/barkpark-changelog-YYYY-MM-DD`, `/papers/barkpark-changelog-YYYY-wWW`, `/papers/barkpark-changelog-YYYY-MM`, `/papers/barkpark-changelog-YYYY`.
- Content hierarchy: Branded edition → period in one sentence → editorial review → progress stories → audience impact → watchlist / next horizon → release shape → source-backed ledger → provenance.

## Design principles
- Lead with reader value: Describe the shipped outcome before its repository mechanics.
- Review, do not transcribe: Synthesize the period into a defensible point of view; counts and commit subjects are evidence, not the story.
- Brand the period: Every edition earns a short editorial theme that makes the day, week, or month memorable without becoming promotional.
- Translate across audiences: Explain product, operating, and business relevance in ordinary language; never require repository knowledge.
- Be candid about uncertainty: Separate shipped facts from interpretation, risks, and future signals. Never invent customers, revenue, adoption, deadlines, or promises.
- Familiar at first glance: Use recognizable changelog conventions—release date, category, highlight, details, archive, source.
- Evidence without noise: Keep Git provenance available and explicit, but subordinate it to the product story.
- One premium system: Compose existing Paper blocks and tokens; improve Chronicle authorship rather than forking the renderer.
- Tradeoffs: Editorial clarity outranks exhaustive detail above the fold; exhaustive ledgers remain available lower in each edition.

## Visual language
- Color: Existing evergreen Paper palette; semantic accents only for release categories and status.
- Typography: Existing Paper editorial serif for narrative hierarchy and system sans/mono for metadata, labels, and evidence.
- Spacing/layout rhythm: Preserve the measured 660px prose column, wide evidence band, 92px section beat, and structural rule hierarchy.
- Shape/radius/elevation: Existing restrained Paper cards; no new shadows or decorative chrome.
- Motion: None required for reading; existing theme controls only.
- Imagery/iconography: Product screenshots may be added when real assets exist; do not invent decorative imagery. Use terse text labels rather than icon clutter.

## Components
- Existing components to reuse: Eyebrow, heading, ingress, byline, stats, section/grid, slot-based card with action, chart, lineage, list, callout, divider, and inline link.
- New/changed components: No renderer component required. Chronicle gains an editorial theme, period review callout, source-linked progress-story cards, audience-lens cards, watchlist, and next-horizon section composed from existing blocks.
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
- Tone: Clear, reflective, specific, and human; closer to a thoughtful Linear, Stripe, or Vercel-style release review than an engineering ledger. Confident about shipped facts, restrained about interpretation.
- Terminology: Prefer “shipped,” “release,” “improvement,” and “fix.” Reserve “first-parent,” “digest,” and “renderer” for provenance.
- Microcopy rules: Lead with outcomes; use sentence case; keep labels under five words; avoid unexplained counts; never expose a commit subject as the page's primary promise without rewriting its conventional prefix; use “we” only for a grounded editorial interpretation, never as a substitute for evidence.

## Editorial system
- Edition contract: `theme`, `standfirst`, `review`, two-to-four `progress_stories`, three audience lenses, `watchlist`, and `next_horizon`.
- Scale: Daily editions explain what changed and the immediate effect; weekly editions connect changes into a direction of travel; monthly editions assess durable progress, operating posture, and the next strategic signal; annual editions describe the larger arc.
- Authorship: An AI editorial pass may synthesize the verified event packet. It receives bounded source records and aggregate facts, returns strict structured JSON, and is rejected unless every progress story cites supplied commit identifiers.
- Grounding: Numeric facts are rendered deterministically outside model prose. Model prose must not introduce numbers, customer claims, financial claims, adoption claims, security guarantees, dates, deadlines, or unshipped promises.
- Fallback: If editorial generation is unavailable or invalid, every edition still receives the same narrative sections from a deterministic, source-grounded editor. Generation and publishing fail soft; evidence never disappears.
- Freshness: The scheduled publisher generates editorial copy only for the current day, week, month, and year. Historical editions remain stable at their last published review; full-history generation remains available for verification and deliberate backfills.
- Reader trust: Interpretation is labeled as review or watchlist; the complete source ledger and provenance remain below the editorial layer.

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
