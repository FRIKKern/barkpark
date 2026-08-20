# Re-derivation recipe — the reader's TRUE body typography (v1, paper-excellence wave 1)

Settles the three-way contradiction (16px vs 18px vs 20.48px) that the gap ledger's
"before" column hangs on. Measured 2026-08-12 on https://guerrilla.barkpark.cloud/papers/heggemsnes-act,
viewport 1280x900, devicePixelRatio 1, both `data-theme` states.

VERDICT: reader body prose = **16px / 26.4px lh / letter-spacing normal**. The token
`--bp-body-size: 18px` resolves on the surface and **has zero consumers on the reader**.
The 20.48px number is the **ingress** (`.bp-role-ingress`, `font-size: 1.28rem`, root rem = 16px)
— a different element, not body prose.

## 1. The token is defined and unused on the reader (source)

    git show origin/main:api/assets/paper-surface/paper-surface.css | sed -n '97,100p'
    # .bp-paper-surface, .bp-paper-body { --bp-body-size: var(--tok-reading-body-size); ... }

    git grep -n 'var(--bp-body-size)' origin/main -- 'api/assets/**' 'api/lib/**'
    # ONLY two consumers, neither on the reader:
    #   api/assets/paper-editor/src/styles.css:458   .bp-paper-editor-body   (editor WC)
    #   api/lib/barkpark_web/layouts/root.html.heex:3849  .bp-paper-surface   (STUDIO root layout)

The reader uses a different layout — `api/lib/barkpark_web/layouts/bulldocs.html.heex` —
whose article rule sets a hardcoded line-height and **no font-size**:

    git show origin/main:api/lib/barkpark_web/layouts/bulldocs.html.heex | sed -n '694,698p'
    # .bp-paper-shell.bp-paper-article { max-width: 720px; padding: 56px 40px 96px; line-height: 1.65; }

So body prose inherits `body`'s font-size, which is never set → UA default 16px.
16 x 1.65 = 26.4px, matching the measured line-height exactly.

## 2. Confirm on the served bytes (no browser)

    curl -s https://guerrilla.barkpark.cloud/papers/heggemsnes-act > /tmp/h.html
    grep -c 'font-size: var(--bp-body-size)' /tmp/h.html     # => 0
    grep -o '\.bp-role-ingress {[^}]*}' /tmp/h.html          # => font-size: 1.28rem

Do NOT use unbounded `[^{]*` regexes on this 200KB file — they backtrack for minutes.
Bound every quantifier (`[^}]{0,200}`) or parse with python.

## 3. Confirm in the browser (chrome-devtools MCP)

Open the paper in an ISOLATED browser context and `select_page` it before every
`evaluate_script` — concurrent wave agents share this browser and will navigate the
selected tab out from under you (happened twice during v1; one measurement returned
a different paper's numbers). Guard every script with
`if(!/heggemsnes-act/.test(location.href)) return {ABORT:location.href}`.

    emulate viewport "1280x900x1"
    evaluate: getComputedStyle on (a) a class-less <p> in .bp-paper-article with >300 chars,
              (b) .bp-role-ingress — print fontSize/lineHeight/letterSpacing + outerHTML.slice(0,120)

Expected (identical in `data-theme=dark` and `data-theme=light`; only `color` changes):

| element | font-size | line-height | letter-spacing |
|---|---|---|---|
| body `<p>` (class-less) | 16px | 26.4px | normal |
| `.bp-role-ingress` | 20.48px | 30.72px | normal |
| `h1` | 32px | 35.2px | -0.64px |
| `h2` | 24px | 28.8px | normal |

Column: `.bp-paper-article` max-width 720px, padding `56px 40px 96px` → content measure 640px,
`margin-left` 280px at 1280 (centered), `text-align: start`, `hyphens: auto` on paragraphs.

## 4. Characters per line (the measure number)

Range-walk one text node char by char, bucket by `Math.round(rect.top)`, drop the last
(short) line, average the rest. At 640px / 16px Iowan Old Style: **82–91 CPL, avg ~84–89**
across three consecutive paragraphs. Ingress at 20.48px: ~66 CPL.

## 5. The rem-collapse trap (simulate before you build)

Injecting the "obvious" systemic fix in the live page —

    .bp-paper-surface { font-size: var(--bp-body-size); letter-spacing: var(--bp-body-tracking); }

— moves body to 18px / 29.7px / 0.09px and CPL 84 → 75, but the ingress stays 20.48px
because `1.28rem` is ROOT-relative, so the ingress/body size contrast collapses from
**1.28x to 1.138x**. Every rem-sized role (`eyebrow` .78rem, `byline` .9rem,
`pullquote` 1.2rem, ingress 1.28rem) has the same problem; the `em`-sized ones
(inline code .9em, links .9em) scale correctly. A body-size slice that does not
convert the rem roles to `em` (or re-token them) silently flattens the type scale.

## 6. Consequence worth recording

`.bp-paper-editor-body` (styles.css:458) and the Studio surface (root.html.heex:3849)
DO consume the token, so Studio's edit view renders prose at 18px while the public
reader renders 16px — a real View↔Edit typography divergence that the existing
view-edit-parity harness does not catch (it diffs colors/inline styles, not computed
font-size).
