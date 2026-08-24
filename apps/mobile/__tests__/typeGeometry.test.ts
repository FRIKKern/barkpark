// THE GEOMETRY LEDGER (mob-bl-token-guard-residuals, charter D32/D43).
//
// WHAT THIS EXISTS FOR. S8 moved 189 fontSize/lineHeight literals onto
// src/ui/typography.ts and the ESLint ban keeps them there. Two pins came out
// of that slice: the token module's HEADING values (absolute, after reviewer
// mutant M4) and the #6126 bubble law through ChatSessionScreen. Everything
// else was pinned by NOTHING — the S8 review's mutant M3a changed a Class-B
// lead (a lineHeight the migration introduced where RN's platform default had
// shipped) and the whole suite stayed green, guard included. A one-line edit
// in the token module reflows every screen at once, and a one-token edit at a
// call site reflows one screen; neither had a tripwire.
//
// So this file pins RESOLVED geometry, in three layers:
//
//   1. THE TABLE, ABSOLUTELY — every step and every role as literal numbers.
//      Catches M3a at its source (`scale.md` 15/21 → 15/20 reds here).
//   2. THE NAMED CALL SITES — every StyleSheet.create entry in the app,
//      resolved THROUGH the token table to concrete {fontSize, lineHeight}.
//      Catches a token swap at a call site (TabBar `label` base → md reds
//      here), which layer 1 cannot see.
//   3. THE ANONYMOUS CALL SITES — the inline-style renderers (blocks.tsx,
//      chat.tsx, inlines.tsx) have no stable style key, so they are pinned as
//      a per-file token census. Swapping `scale.sm` → `scale.base` on any
//      renderer moves the histogram and reds here.
//
// The ledger is DERIVED, not hand-maintained: it parses src/**/*.ts(x) with
// the TypeScript AST and resolves spreads/member access against the real
// token module. Adding a style entry is expected to red this file — that is
// the design (the diff shows the reviewer exactly which geometry moved).
// Regenerate the expected tables with:
//
//     BP_DUMP_TYPE_LEDGER=1 npx jest typeGeometry
//
// and paste the printed literals below.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

import * as ts from 'typescript'

import { roles, scale } from '../src/ui/typography'

const SRC = join(__dirname, '..', 'src')
const TOKEN_MODULE = 'ui/typography.ts'

interface Pair {
  /** `'?'` means the site sets this field but the ledger cannot resolve the
   * value — a laundered const, a call, a cast. It renders as `?` and therefore
   * reds the pin: an unresolvable type value is a finding, not a blank. */
  fontSize?: number | '?'
  lineHeight?: number | '?'
  fontFamily?: string
}

const TABLES: Record<string, Record<string, Pair>> = { scale, roles }

/** `scale.xs` / `roles.chatBody` → the token's own pair; `scale.md.fontSize` →
 * just that field. Returns null for anything that is not a token reference. */
function resolveToken(node: ts.Node): { name: string; pair: Pair } | null {
  if (!ts.isPropertyAccessExpression(node)) return null
  const outer = node.name.text

  // two-level: <table>.<token>
  if (ts.isIdentifier(node.expression)) {
    const table = TABLES[node.expression.text]
    const step = table?.[outer]
    if (!step) return null
    const pair: Pair = { fontSize: step.fontSize, lineHeight: step.lineHeight }
    if (step.fontFamily !== undefined) pair.fontFamily = step.fontFamily
    return { name: `${node.expression.text}.${outer}`, pair }
  }

  // three-level: <table>.<token>.<field>
  if (ts.isPropertyAccessExpression(node.expression) && (outer === 'fontSize' || outer === 'lineHeight')) {
    const inner = resolveToken(node.expression)
    if (!inner) return null
    return { name: `${inner.name}.${outer}`, pair: { [outer]: inner.pair[outer] } }
  }
  return null
}

/** The resolved geometry of ONE style object literal, or null if it sets none. */
function resolveStyleObject(obj: ts.ObjectLiteralExpression): Pair | null {
  const out: Pair = {}
  let touched = false
  for (const m of obj.properties) {
    if (ts.isSpreadAssignment(m)) {
      const tok = resolveToken(m.expression)
      if (!tok) continue
      Object.assign(out, tok.pair)
      touched = true
      continue
    }
    if (!ts.isPropertyAssignment(m)) continue
    const key = ts.isIdentifier(m.name) || ts.isStringLiteral(m.name) ? m.name.text : null
    if (key !== 'fontSize' && key !== 'lineHeight' && key !== 'fontFamily') continue
    // A raw literal here is what the ESLint guard exists to prevent, but the
    // ledger still resolves one rather than skipping it silently: if the guard
    // ever regresses, the number must show up in the diff, not vanish.
    if (ts.isNumericLiteral(m.initializer) && key !== 'fontFamily') {
      out[key] = Number(m.initializer.text)
      touched = true
      continue
    }
    if (ts.isStringLiteral(m.initializer) && key === 'fontFamily') {
      out.fontFamily = m.initializer.text
      touched = true
      continue
    }
    const tok = resolveToken(m.initializer)
    if (tok) {
      Object.assign(out, tok.pair)
      touched = true
      continue
    }
    // Sets the field, but through something the ledger cannot follow — the
    // laundered `fontSize: ROW_SIZE`, a cast, a call. The ESLint guard is the
    // first net and reds these; recording `?` here is the second, so a guard
    // regression cannot make a site invisible to BOTH.
    if (key !== 'fontFamily') {
      out[key] = '?'
      touched = true
    }
  }
  return touched ? out : null
}

function sourceFiles(): string[] {
  const found: string[] = []
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir).sort()) {
      const abs = join(dir, entry)
      if (statSync(abs).isDirectory()) {
        walk(abs)
      } else if (/\.tsx?$/.test(entry)) {
        found.push(abs)
      }
    }
  }
  walk(SRC)
  return found
}

interface Ledger {
  /** `<file>#<styleKey>` → the resolved pair, as a compact tuple string. */
  named: Record<string, string>
  /** `<file>` → token name → how many times it is referenced anonymously. */
  census: Record<string, Record<string, number>>
}

function fmt(p: Pair): string {
  const face = p.fontFamily === undefined ? '' : ` ${p.fontFamily}`
  return `${p.fontSize ?? '-'}/${p.lineHeight ?? '-'}${face}`
}

function buildLedger(): Ledger {
  const named: Record<string, string> = {}
  const census: Record<string, Record<string, number>> = {}

  for (const abs of sourceFiles()) {
    const rel = relative(SRC, abs).split(/[\\/]/).join('/')
    if (rel === TOKEN_MODULE) continue
    const text = readFileSync(abs, 'utf8')
    const sf = ts.createSourceFile(abs, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)

    // Pass 1 — every StyleSheet.create entry, by name.
    const consumed = new Set<ts.Node>()
    const findSheets = (node: ts.Node) => {
      const arg = ts.isCallExpression(node) ? node.arguments[0] : undefined
      if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        ts.isIdentifier(node.expression.expression) &&
        node.expression.expression.text === 'StyleSheet' &&
        node.expression.name.text === 'create' &&
        node.arguments.length === 1 &&
        arg !== undefined &&
        ts.isObjectLiteralExpression(arg)
      ) {
        for (const m of arg.properties) {
          if (!ts.isPropertyAssignment(m) || !ts.isObjectLiteralExpression(m.initializer)) continue
          const pair = resolveStyleObject(m.initializer)
          if (!pair) continue
          const key = ts.isIdentifier(m.name) || ts.isStringLiteral(m.name) ? m.name.text : '?'
          named[`${rel}#${key}`] = fmt(pair)
          consumed.add(m.initializer)
        }
      }
      ts.forEachChild(node, findSheets)
    }
    findSheets(sf)

    // Pass 2 — every OTHER token reference, counted. Outermost only: a
    // `scale.md.fontSize` counts once, as itself, not also as `scale.md`.
    const counts: Record<string, number> = {}
    const walkCensus = (node: ts.Node, inConsumed: boolean) => {
      const nowConsumed = inConsumed || consumed.has(node)
      if (!nowConsumed) {
        const tok = resolveToken(node)
        if (tok) {
          counts[tok.name] = (counts[tok.name] ?? 0) + 1
          return // do not descend into the reference we just counted
        }
      }
      ts.forEachChild(node, (c) => walkCensus(c, nowConsumed))
    }
    walkCensus(sf, false)
    if (Object.keys(counts).length > 0) {
      census[rel] = Object.fromEntries(Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)))
    }
  }

  return {
    named: Object.fromEntries(Object.entries(named).sort(([a], [b]) => a.localeCompare(b))),
    census: Object.fromEntries(Object.entries(census).sort(([a], [b]) => a.localeCompare(b))),
  }
}

/* ── 1. the table, absolutely ────────────────────────────────────────────── */

describe('the token table is pinned to numbers, not to relations', () => {
  // The S8 suite pinned the 8 census SIZES and the heading roles' absolute
  // pairs. Everything else was pinned by a ratio band (1 < lead/size < 1.6),
  // which is why mutant M3a passed: 15/21 → 15/20 is still in the band. These
  // are the pairs the app shipped after the migration; a lead that moves here
  // moves every call site that spreads it.
  it('the 8 chrome steps', () => {
    expect(Object.entries(scale).map(([k, s]) => `${k} ${s.fontSize}/${s.lineHeight}`)).toEqual([
      'micro 11/15',
      'xs 12/16',
      'sm 13/18',
      'base 14/20',
      'md 15/21',
      'lg 16/22',
      'xl 20/26',
      'display 26/32',
    ])
  })

  it('all 24 named roles', () => {
    expect(Object.entries(roles).map(([k, r]) => `${k} ${fmt(r)}`)).toEqual([
      'readingBody 16/26 serif',
      'userBubble 16/23',
      'paperH1 26/34',
      'paperH2 22/29',
      'paperH3 18/23',
      'paperIngress 19/30 serif',
      'statValue 24/30',
      'brandWordmark 34/40',
      'deviceCode 30/36',
      'chatBody 16/26',
      'chatH1 20/26',
      'chatH2 18/23',
      'chatH3 16/21',
      'chatApparatus 12/18',
      'sectionTitle 22/29',
      'paperPullquote 20/30 serif',
      'calloutBody 15/23',
      'codeBlock 13/20',
      'tocRow 14/24',
      'backGlyph 26/28',
      'sendGlyph 20/24',
      'stopGlyph 14/16',
      'jumpGlyph 17/20',
      'composerInput 16/21',
    ])
  })
})

/* ── the frozen tables ───────────────────────────────────────────────────── */

// Every StyleSheet entry in the app that sets type, resolved through the token
// module. Three entries are the OPEN QUESTION this slice could not close on a
// simulator and deliberately did not guess at (see typography.ts, "the
// interactive sites"): `ConnectScreen#input` 15/21 and `TaskDetailScreen#input`
// 14/20 are TextInputs that GAINED a lead where the platform default had
// shipped, and `TabBar#badgeText` 11/15 is a glyph in an 18pt box that did the
// same — the very shape `composerInput` (16/21) and the four *Glyph roles were
// minted to preserve. They are written out here so the device pass has one
// place to look and one line to change.
const NAMED: Record<string, string> = {
  'chat/PickerSheet.tsx#archiveText': '15/21',
  'chat/PickerSheet.tsx#chipText': '14/20',
  'chat/PickerSheet.tsx#degraded': '14/20',
  'chat/PickerSheet.tsx#note': '13/18',
  'chat/PickerSheet.tsx#rowLabel': '12/16',
  'papers/portabledoc/MermaidIsland.tsx#loadingLabel': '11/15',
  'papers/portabledoc/MermaidIsland.tsx#placeholderLabel': '12/16',
  'papers/portabledoc/MermaidIsland.tsx#placeholderSource': '11/15 monospace',
  'papers/portabledoc/MermaidIsland.tsx#truncatedNote': '11/15',
  'screens/ChatScreen.tsx#body': '15/21',
  'screens/ChatScreen.tsx#capNote': '12/16',
  'screens/ChatScreen.tsx#link': '14/20',
  'screens/ChatScreen.tsx#metaText': '12/16',
  'screens/ChatScreen.tsx#muted': '13/18',
  'screens/ChatScreen.tsx#notice': '12/16',
  'screens/ChatScreen.tsx#pendingText': '11/15',
  'screens/ChatScreen.tsx#shelfTitle': '22/29',
  'screens/ChatScreen.tsx#stateLabel': '12/16',
  'screens/ChatScreen.tsx#summary': '14/20',
  'screens/ChatScreen.tsx#swipeLabel': '13/18',
  'screens/ChatScreen.tsx#title': '16/22',
  'screens/ChatSessionScreen.tsx#assistantText': '16/26',
  'screens/ChatSessionScreen.tsx#back': '26/28',
  'screens/ChatSessionScreen.tsx#body': '15/21',
  'screens/ChatSessionScreen.tsx#cardBody': '15/21',
  'screens/ChatSessionScreen.tsx#cardStatus': '13/18',
  'screens/ChatSessionScreen.tsx#cardTitle': '11/15',
  'screens/ChatSessionScreen.tsx#headerTitle': '16/22',
  'screens/ChatSessionScreen.tsx#input': '16/21',
  'screens/ChatSessionScreen.tsx#jumpGlyph': '17/20',
  'screens/ChatSessionScreen.tsx#link': '14/20',
  'screens/ChatSessionScreen.tsx#logHeaderText': '13/18 monospace',
  'screens/ChatSessionScreen.tsx#metaBadge': '12/16',
  'screens/ChatSessionScreen.tsx#muted': '13/18',
  'screens/ChatSessionScreen.tsx#notice': '12/16',
  'screens/ChatSessionScreen.tsx#pillBtnText': '14/20',
  'screens/ChatSessionScreen.tsx#queuedBadge': '11/15',
  'screens/ChatSessionScreen.tsx#sendGlyph': '20/24',
  'screens/ChatSessionScreen.tsx#stopGlyph': '14/16',
  'screens/ChatSessionScreen.tsx#systemLine': '13/18',
  'screens/ChatSessionScreen.tsx#userText': '16/23',
  'screens/ConnectScreen.tsx#body': '15/21',
  'screens/ConnectScreen.tsx#heading': '26/32',
  'screens/ConnectScreen.tsx#input': '15/21',
  'screens/ConnectScreen.tsx#link': '14/20',
  'screens/ConnectScreen.tsx#muted': '13/18',
  'screens/ConnectScreen.tsx#primaryButtonText': '15/21',
  'screens/ConnectScreen.tsx#serverName': '16/22',
  'screens/LoginScreen.tsx#brand': '34/40',
  'screens/LoginScreen.tsx#code': '30/36',
  'screens/LoginScreen.tsx#codeLabel': '13/18',
  'screens/LoginScreen.tsx#errorText': '15/21',
  'screens/LoginScreen.tsx#linkText': '14/20',
  'screens/LoginScreen.tsx#primaryButtonText': '16/22',
  'screens/LoginScreen.tsx#statusText': '14/20',
  'screens/LoginScreen.tsx#tagline': '15/21',
  'screens/PaperReaderScreen.tsx#back': '15/21',
  'screens/PaperReaderScreen.tsx#body': '15/21',
  'screens/PaperReaderScreen.tsx#headerTitle': '15/21',
  'screens/PaperReaderScreen.tsx#link': '14/20',
  'screens/PaperReaderScreen.tsx#muted': '13/18',
  'screens/PaperReaderScreen.tsx#staleText': '12/16',
  'screens/PapersScreen.tsx#body': '15/21',
  'screens/PapersScreen.tsx#description': '13/18',
  'screens/PapersScreen.tsx#link': '14/20',
  'screens/PapersScreen.tsx#metaText': '12/16',
  'screens/PapersScreen.tsx#muted': '13/18',
  'screens/PapersScreen.tsx#pill': '11/15',
  'screens/PapersScreen.tsx#staleText': '12/16',
  'screens/PapersScreen.tsx#title': '15/21',
  'screens/TaskDetailScreen.tsx#action': '14/20',
  'screens/TaskDetailScreen.tsx#back': '14/20',
  'screens/TaskDetailScreen.tsx#body': '15/21',
  'screens/TaskDetailScreen.tsx#cardTitle': '12/16',
  'screens/TaskDetailScreen.tsx#chip': '11/15',
  'screens/TaskDetailScreen.tsx#criterionText': '14/20',
  'screens/TaskDetailScreen.tsx#factLabel': '12/16',
  'screens/TaskDetailScreen.tsx#factValue': '13/18',
  'screens/TaskDetailScreen.tsx#fenceLine': '12/16',
  'screens/TaskDetailScreen.tsx#headerTitle': '16/22',
  'screens/TaskDetailScreen.tsx#input': '14/20',
  'screens/TaskDetailScreen.tsx#link': '14/20',
  'screens/TaskDetailScreen.tsx#mark': '15/21',
  'screens/TaskDetailScreen.tsx#metaText': '12/16',
  'screens/TaskDetailScreen.tsx#muted': '13/18',
  'screens/TaskDetailScreen.tsx#notice': '12/16',
  'screens/TaskDetailScreen.tsx#nowText': '14/20',
  'screens/TasksScreen.tsx#body': '15/21',
  'screens/TasksScreen.tsx#link': '14/20',
  'screens/TasksScreen.tsx#metaText': '12/16',
  'screens/TasksScreen.tsx#muted': '13/18',
  'screens/TasksScreen.tsx#nowLine': '13/18',
  'screens/TasksScreen.tsx#priority': '11/15',
  'screens/TasksScreen.tsx#sectionHeader': '12/16',
  'screens/TasksScreen.tsx#staleText': '12/16',
  'screens/TasksScreen.tsx#title': '15/21',
  'ui/TabBar.tsx#badgeText': '11/15',
  'ui/TabBar.tsx#label': '14/20',
}

// The inline-style renderers, per family module since the D49 split (the old
// blocks.tsx monolith's census redistributed token-for-token; register.ts's 8
// role references ARE the two registers — paper + chat body/H1/H2/H3 — and
// each family file carries its own block chrome). Adding a block renderer
// moves a count here and reds this test — intended: the reviewer then sees
// which rung the new block chose instead of taking it on trust, and a
// renderer slice moves only its OWN family's rows (D49's recorded shared-file
// exception; conflicts regen-resolve).
const CENSUS: Record<string, Record<string, number>> = {
  // The forming-block placeholder (mob-rt-s6). Two references, two registers:
  // `scale.xs` is the italic muted "rendering chart…" label — the same rung
  // registry.tsx's honest-degrade card uses, because this IS that card's
  // sibling; `roles.chatBody` is the partial prose above the box, at the SAME
  // settled assistant measure as the live tail Text directly above it — a
  // smaller rung would make one paragraph change size mid-turn and change back
  // at settle. The bars carry no type at all — they are Views, never Text.
  'chat/StreamSkeleton.tsx': {
    'roles.chatBody': 1,
    'scale.xs': 1,
  },
  // mob-zb-s4's five nav/code natives. The three chatApparatus references are
  // the mono APPARATUS rows (a diff row, a diff file sub-header, a filetree
  // row) — the token's own docstring names "a diff line", and using it here
  // keeps mobile's two diff surfaces (chat-tool-diff and the paper `diff`
  // block) at one measure instead of two.
  'papers/portabledoc/blocks/core-code.tsx': {
    'roles.chatApparatus': 3,
    'scale.micro': 3,
    'scale.sm': 2,
    'scale.xs': 6,
  },
  'papers/portabledoc/blocks/core-container.tsx': {
    'roles.tocRow': 1,
    'scale.base': 1,
    'scale.md': 4,
    'scale.micro': 1,
    'scale.xs': 2,
  },
  'papers/portabledoc/blocks/core-doc.tsx': {
    'scale.base': 5,
    'scale.md': 1,
    'scale.micro': 12,
    'scale.sm': 12,
    'scale.xs': 1,
  },
  'papers/portabledoc/blocks/core-media.tsx': {
    'roles.codeBlock': 1,
    // sm ×3 = the figure/video/asciicast caption rung: the two degrade cards
    // (mob-zb-s7, D46d) label themselves at the same step a figcaption speaks at,
    // one rung under body, because a card is apparatus about the content.
    'scale.sm': 3,
    'scale.xs': 1,
  },
  'papers/portabledoc/blocks/core-prose.tsx': {
    'roles.calloutBody': 1,
    'roles.paperIngress': 1,
    'roles.paperPullquote': 1,
    'scale.base': 1,
    'scale.sm': 3,
    'scale.xs': 2,
  },
  'papers/portabledoc/blocks/dataviz.tsx': {
    'roles.statValue': 1,
    // The jarl figure family's lineage value figure: mono `md` bold accent.
    'scale.md': 1,
    'scale.md.fontSize': 1,
    // The round-2 natives (mob-zb-s5, D56) are apparatus-heavy: `micro` is the
    // axis tick / heat label / marginal-sum voice and `xs` the proportional
    // row's label+digit. `scale.micro.lineHeight` is the ONE resolved-geometry
    // read in the family — the chart's y tick is centred on its gridline by
    // half its own line box, which is exactly the kind of computed offset the
    // ESLint ban pushes through the token module rather than a literal.
    //
    // The jarl figure family (duel / lineage + the kilde stamp + the stat
    // unit/body extension) grew the census: micro 7→11 (duel legends/delta,
    // lineage overline, the two nested unit runs' fontSize, the kilde line),
    // xs 4→5 (stat body prose beside the label), and the `.fontSize`/
    // `.lineHeight` singles — nested Text runs take `<token>.fontSize` only
    // (the nested-run law statCard records), while the duel label and lineage
    // title/body override `bodyText(ctx)`'s measure with the sm/xs pair.
    // route grew micro 11→12: the meta row (sport · distance · elevation ·
    // duration) is one micro mono run under the track, the chart-tick idiom.
    'scale.micro': 12,
    'scale.micro.fontSize': 2,
    'scale.micro.lineHeight': 1,
    'scale.sm': 4,
    'scale.sm.fontSize': 2,
    'scale.sm.lineHeight': 2,
    'scale.xs': 5,
    'scale.xs.fontSize': 2,
    'scale.xs.lineHeight': 1,
  },
  'papers/portabledoc/blocks/paper-links.tsx': {
    'scale.lg': 1,
    'scale.md': 1,
    'scale.micro': 1,
    'scale.sm': 1,
  },
  'papers/portabledoc/blocks/sheet.tsx': {
    'scale.base': 1,
    'scale.sm': 1,
    'scale.xs': 2,
  },
  'papers/portabledoc/blocks/forms.tsx': {
    // base ×2 = the question prompt and its static control rows (a control is
    // read at body measure — it is the answer affordance, not apparatus);
    // sm ×4 = the two dim context lines (rationale and recommendation) plus
    // the field-number definition row's label and value
    // (pbw-fix-field-number-react — label chrome, no prose measure).
    'scale.base': 2,
    'scale.sm': 4,
  },
  'papers/portabledoc/blocks/math.tsx': {
    // The equation's THREE steps, declared once each in the STEPS table: lg is
    // the display measure, md the inline one, xs the single reduced step every
    // super/subscript renders at. sm ×1 is the "no tex source" line.
    'scale.lg': 1,
    'scale.md': 1,
    'scale.sm': 1,
    'scale.xs': 1,
  },
  'papers/portabledoc/blocks/table.tsx': {
    'scale.sm': 2,
  },
  'papers/portabledoc/blocks/taskboard.tsx': {
    'scale.base': 3,
    'scale.micro': 5,
    'scale.sm': 4,
  },
  'papers/portabledoc/chat.tsx': {
    'roles.chatApparatus': 4,
    'scale.micro': 1,
    'scale.sm': 1,
    'scale.xs': 3,
  },
  'papers/portabledoc/inlines.tsx': {
    'scale.sm.fontSize': 1,
  },
  'papers/portabledoc/register.ts': {
    'roles.chatBody': 1,
    'roles.chatH1': 1,
    'roles.chatH2': 1,
    'roles.chatH3': 1,
    'roles.paperH1': 1,
    'roles.paperH2': 1,
    'roles.paperH3': 1,
    'roles.readingBody': 1,
  },
  'papers/portabledoc/registry.tsx': {
    'scale.xs': 1,
  },
}

/* ── 2 + 3. the call sites, resolved ─────────────────────────────────────── */

describe('every call site resolves to the geometry the app shipped', () => {
  const ledger = buildLedger()

  if (process.env.BP_DUMP_TYPE_LEDGER === '1') {
    process.stdout.write(`${JSON.stringify(ledger, null, 2)}\n`)
  }

  it('the named StyleSheet entries', () => {
    expect(ledger.named).toEqual(NAMED)
  })

  it('the anonymous inline-style renderers, as a per-file token census', () => {
    expect(ledger.census).toEqual(CENSUS)
  })

  it('resolves a real spread, not an empty ledger (the harness can fail)', () => {
    // A resolver that silently matched nothing would make both pins vacuous.
    expect(Object.keys(ledger.named).length).toBeGreaterThan(80)
    expect(ledger.named['ui/TabBar.tsx#label']).toBe('14/20')
    expect(ledger.census['papers/portabledoc/blocks/core-prose.tsx']?.['scale.sm']).toBeGreaterThan(0)
  })
})
