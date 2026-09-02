// sheet family (charter D49): `sheet` — the embed's dense snapshot as an
// ALIGNED horizontal-scroll grid (charter D46b). Shape source:
// js/packages/react/src/blocks/sheet.ts; floor: internal/pdrender/sheet.go.
//
// WHY A GRID AND NOT A CARD. The 80-column TUI draws the whole character grid,
// so a summary card on a 390pt phone would be a recorded regression BELOW the
// TUI bar. D46b rules the grid in.
//
// THE ALIGNMENT LAW — the reason this renderer exists as its own shape. Every
// cell at column index i takes the SAME width in EVERY row: one `colWidth(i)`
// consulted per cell, never a per-cell min/max. The sibling table renderer
// (./table.tsx) does the opposite (minWidth 96 / maxWidth 220 per cell, so
// each row lays itself out and columns can misalign) — tolerable for a prose
// table, fatal for a sheet, and D46b forbids copying it here. Rows are PADDED
// to the widest row so a ragged snapshot still yields a rectangular grid
// instead of a grid whose right edge wanders.
//
// COLUMN WIDTHS. `snapshot.col_widths` are PIXEL hints from the Studio grid.
// react uses them verbatim as `width:Npx`; this renderer uses them verbatim as
// RN pt (the TUI cannot — its widths are character counts, so sheet.go drops
// them and auto-sizes). Only a positive INTEGER counts, matching react's
// `Number.isInteger` gate, and the value is clamped to a sane band — BOTH
// bounds are narrowings from react, which uses any positive integer verbatim,
// and each has its own reason. MAX: an unbounded authored width would blow the
// ScrollView's content size, the same hazard sheet.go clamps at its own
// `maxColWidth`. MIN: the web can afford a 4px spacer column because the
// reader can still widen the window; on a phone the same column is 4pt of
// unreachable content, so the floor keeps every authored cell readable rather
// than faithfully invisible. FLIP TRIGGER for the min: deliberate spacer
// columns showing up in the live corpus, where hiding them beats showing them.
//
// MERGES ARE A RECORDED NARROWING (D46b). `snapshot.merges` is deliberately
// NOT read. The covered cells of a merged range are already "" in the dense
// snapshot, so rendering every cell keeps the anchor value showing exactly
// once and the column geometry holds; RN has no colspan/rowspan, and faking a
// span by widening one cell would break the alignment law above (react emits
// real colspan/rowspan; the TUI ignores merges for the same character-grid
// reason). FLIP TRIGGER: real merge usage in the live corpus, or an explicit
// ask — at which point the honest RN shape is an absolutely-positioned overlay
// over the fixed grid, not a variable-width cell.
//
// REGISTER (D50) — register-BLIND, and the reference surfaces' own CSS is the
// evidence, not a convenience: paper-surface.css paints `.bp-sheet__td` in the
// MONO face at 0.88rem and `.bp-sheet__th` as a 0.78rem uppercase label. A
// spreadsheet cell is tabular chrome, never a prose run, so there is no
// bodyText(ctx) measure to carry here and nothing serif that could leak into
// the chat register. This paragraph IS the per-type ruling D50's crown
// REGISTER_BLIND allowlist asks for (the table/divider class).
import type { ReactNode } from 'react'
import { Linking, ScrollView, Text, View, type TextStyle } from 'react-native'

import { scale } from '../../../ui/typography'
import { asList, isMap, openableUrl, str } from '../model'
import { MONO, type BlockCtx, type Render } from '../register'

/** No `col_widths` entry for this column → the D46b default measure. */
const DEFAULT_COL_W = 120
const MIN_COL_W = 32
const MAX_COL_W = 600

/** A fixed-width cell clamps rather than growing without bound: the TUI
 * truncates to exactly one line, the web wraps forever. Two lines is the
 * recorded middle — a long note stays readable without one cell setting the
 * height of the whole row band. */
const CELL_LINES = 2

/** Sheets.Engine.error_values — a cell whose ENTIRE value is one of these
 * renders red + bold on every surface.
 *
 * This is a MIRROR of `Barkpark.Plugins.Sheets.Engine.error_values/0`
 * (@canonical capability:engine-error-vocabulary), and it was the SIXTH copy —
 * the one #15404 named and left unguarded while locking the react mirror. It
 * had already drifted: #15374 added `#NAME?` engine-side and this set did not
 * learn it, so a `#NAME?` cell rendered on mobile as ordinary text while every
 * other surface painted it red. `__tests__/sheetErrorVocabulary.test.ts` now
 * pins this set to the SAME engine-generated fixture the web and react mirrors
 * consume (`web/__tests__/fixtures/engine-errors.json`, asserted equal to
 * `Engine.error_values/0` by api/test/barkpark/sheets_parity_test.exs), so
 * neither side can drift alone again. Exported for that test and for
 * `__tests__/gridNatives.test.tsx` — it is not part of any public entry point.
 */
export const ERROR_VALUES = new Set(['#CYCLE!', '#REF!', '#VALUE!', '#DIV/0!', '#N/A', '#NUM!', '#SPILL!', '#NAME?'])

// The four value-shape gates, byte-copied from react's sheet.ts so the same
// cell reads the same way on both surfaces.
const SHEET_URL_RE = /^https?:\/\/[^\s<>"']+$/i
const NUMERIC_RE = /^-?\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?%?$/
const TEMPORAL_RE = /^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}:\d{2})?$/
const BG_RE = /^#[0-9a-fA-F]{6}$/

type Align = 'left' | 'center' | 'right'

interface CellStyle {
  bold: boolean
  italic: boolean
  bg?: string
  align?: Align
}

/** The declared width of column `idx`, in RN pt. */
function colWidth(colWidths: unknown, idx: number): number {
  if (Array.isArray(colWidths)) {
    const w: unknown = colWidths[idx]
    if (typeof w === 'number' && Number.isInteger(w) && w > 0) {
      return Math.min(Math.max(w, MIN_COL_W), MAX_COL_W)
    }
  }
  return DEFAULT_COL_W
}

/** `snapshot.styles["r,c"]` → the four honored properties (b/i/bg/al). A `bg`
 * that is not a strict #rrggbb is dropped, exactly as Sheets.CondFormat's own
 * `valid_bg?` gate drops it. */
function cellStyle(styles: unknown, r: number, c: number): CellStyle {
  const s: unknown = isMap(styles) ? styles[`${r},${c}`] : undefined
  if (!isMap(s)) return { bold: false, italic: false }
  const al = s.al
  const bg = s.bg
  return {
    bold: s.b === true,
    italic: s.i === true,
    bg: typeof bg === 'string' && BG_RE.test(bg) ? bg : undefined,
    align: al === 'left' || al === 'center' || al === 'right' ? al : undefined,
  }
}

/** The default alignment a value EARNS by its own shape — booleans centre,
 * numbers and ISO temporals go right. An explicit `al` always wins. */
function defaultAlign(cell: string): Align | undefined {
  if (cell === 'TRUE' || cell === 'FALSE') return 'center'
  if (NUMERIC_RE.test(cell) || TEMPORAL_RE.test(cell)) return 'right'
  return undefined
}

function openSheetLink(url: string): void {
  Linking.openURL(url).catch(() => {
    // Honest no-op: a cell whose URL cannot open must never take the reader down.
  })
}

/* ── the cells ──────────────────────────────────────────────────────────────── */

function headCell(label: string, width: number, ctx: BlockCtx, key: number): ReactNode {
  return (
    <View key={key} style={{ width, paddingVertical: 6, paddingHorizontal: 10 }}>
      {/* `.bp-sheet__th`'s treatment (uppercase, 0.04em tracking, ink-soft) at
          its size. The web's serif FACE does not travel: mobile carries serif
          only on the reading roles, and a 12pt uppercase serif label inside a
          120pt column reads worse than the chrome sans. */}
      <Text
        numberOfLines={CELL_LINES}
        style={{
          ...scale.xs,
          fontWeight: '700',
          letterSpacing: 0.5,
          color: ctx.theme.textMuted,
        }}
      >
        {label.toUpperCase()}
      </Text>
    </View>
  )
}

function bodyCell(
  value: string,
  r: number,
  c: number,
  styles: unknown,
  width: number,
  ctx: BlockCtx,
): ReactNode {
  const cs = cellStyle(styles, r, c)
  const isError = ERROR_VALUES.has(value)
  // The URL gate is react's whole-string http(s) test, then the shared
  // openableUrl seam actually opens it — the same two-step the inline link
  // takes, so an exotic value can never become a tap target by regex alone.
  const url = SHEET_URL_RE.test(value) ? openableUrl(value) : undefined
  const style: TextStyle = {
    ...scale.base,
    fontFamily: MONO,
    textAlign: cs.align ?? defaultAlign(value) ?? 'left',
    color: isError ? ctx.theme.danger : url === undefined ? ctx.theme.text : ctx.theme.accent,
  }
  if (cs.bold || isError) style.fontWeight = '700'
  if (cs.italic) style.fontStyle = 'italic'
  if (url !== undefined) style.textDecorationLine = 'underline'
  return (
    <View
      key={c}
      style={{ width, paddingVertical: 6, paddingHorizontal: 10, backgroundColor: cs.bg }}
    >
      <Text
        numberOfLines={CELL_LINES}
        style={style}
        onPress={url === undefined ? undefined : () => openSheetLink(url)}
      >
        {value}
      </Text>
    </View>
  )
}

/* ── the honest non-grid states ─────────────────────────────────────────────── */

/** A `sheet` embed that never resolved (a ref with no snapshot) and an empty
 * one are DIFFERENT facts, so they say different things: react renders an
 * invisible empty <table> for both, which is the one thing a reader cannot
 * act on. */
function sheetState(label: string, ctx: BlockCtx, key: number): ReactNode {
  return (
    <Text
      key={key}
      style={{ ...scale.sm, fontStyle: 'italic', color: ctx.theme.textMuted, marginVertical: 10 }}
    >
      {label}
    </Text>
  )
}

/* ── the grid ───────────────────────────────────────────────────────────────── */

const sheet: Render = (b, ctx, key) => {
  if (!isMap(b.snapshot)) return sheetState('[sheet — unresolved]', ctx, key)
  const snap = b.snapshot
  const head = asList(snap.head).map(str)
  const rows = asList(snap.rows).map((row) => asList(row).map(str))

  // The rectangle: the widest declared row wins, and every row is padded to it
  // (the alignment law — a short row must still leave its columns standing).
  const cols = Math.max(head.length, ...rows.map((r) => r.length), 0)
  if (cols === 0) return sheetState('(empty sheet)', ctx, key)

  const widths = Array.from({ length: cols }, (_, c) => colWidth(snap.col_widths, c))
  const styles = snap.styles

  return (
    <View key={key} style={{ marginVertical: 10 }}>
      <ScrollView horizontal>
        <View
          style={{
            borderWidth: 1,
            borderColor: ctx.theme.border,
            borderRadius: 6,
            overflow: 'hidden',
          }}
        >
          {head.length > 0 && (
            <View
              style={{
                flexDirection: 'row',
                backgroundColor: ctx.theme.surface,
                borderBottomWidth: 2,
                borderBottomColor: ctx.theme.border,
              }}
            >
              {widths.map((w, c) => headCell(head[c] ?? '', w, ctx, c))}
            </View>
          )}
          {rows.map((row, r) => (
            <View
              key={r}
              style={{
                flexDirection: 'row',
                borderTopWidth: r === 0 ? 0 : 1,
                borderTopColor: ctx.theme.border,
              }}
            >
              {widths.map((w, c) => bodyCell(row[c] ?? '', r, c, styles, w, ctx))}
            </View>
          ))}
        </View>
      </ScrollView>
      {/* OUTSIDE the h-scroll on purpose: a note inside it scrolls away from
          the reader who most needs it. The string is byte-matched to walk.ex
          sheet_truncation_note/3, react's own note and sheet.go's — the row
          count is the count SHOWN, never the sheet's true height. */}
      {snap.truncated === true && (
        <Text style={{ ...scale.xs, color: ctx.theme.textMuted, marginTop: 6 }}>
          {`Sheet truncated — showing the first ${rows.length} rows`}
        </Text>
      )}
    </View>
  )
}

export const sheetRenderers: Record<string, Render> = {
  sheet,
}
