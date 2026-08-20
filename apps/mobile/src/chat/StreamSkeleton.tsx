// The forming-block placeholder — the phone's twin of the Studio transcript's
// `skeleton/1` (api/lib/barkpark_web/live/studio/chat_live.ex:3859-3907).
//
// WHAT IT IS FOR. While an answer is still streaming, the server classifies the
// block it is part-way through emitting and says so. Without this the phone
// either shows nothing (a dead screen mid-turn) or shows the raw half-written
// source (noise that looks like a broken answer). This says the honest thing
// instead — "rendering chart…" over a chart-shaped placeholder — so the reader
// knows WHAT is coming and that it is still coming.
//
// THREE LAWS, all load-bearing.
//
// 1. THE VOCABULARY IS THE SERVER'S, exactly seven labels, no more:
//    diagram · chart · stats · table · callout · code · block. That set IS
//    `skeleton_label/1` (chat_live.ex:5897-5903) including its `_ -> "block"`
//    fallback, so an unknown kind degrades to the generic shape labelled
//    "block" — never empty, never a throw. Inventing an eighth label here would
//    render a word the server can never send.
//
// 2. IT EXTENDS THE APP'S EXISTING HONEST-DEGRADE IDIOM rather than inventing a
//    visual language: the 1px dashed `theme.border` box with radius 6, padding
//    10, marginVertical 6 and an italic muted xs label is `unknownBlock` from
//    src/papers/portabledoc/registry.tsx:43-64. A reader who has met the
//    "Unsupported block" card already knows how to read this one: dashed means
//    "this is the app being honest about what it cannot show you yet".
//    Every colour is a `theme` member and every type geometry is a `scale` or
//    `roles` token — the package's type guard is an inverted whitelist, so a
//    hand-typed fontSize/lineHeight anywhere in here reds the lint.
//
// 3. THE BARS ARE NEVER TEXT. Every shape is a `View` — no glyphs, no lorem, no
//    fabricated content. A placeholder that renders text is a placeholder that
//    can be misread as the answer.
//
// THE ANIMATION, and the reason it is written this carefully. This is the first
// `Animated.loop` in the app (the only other `Animated` use is ChatScreen's
// one-shot swipe-dismiss), so there is no precedent and no existing test that
// would notice a leaked driver. A loop runs until something stops it: one
// skeleton per forming block, several blocks per turn, many turns per session —
// an un-stopped loop is a leak PER TURN. The effect's cleanup stops it, and
// __tests__/streamSkeleton.test.tsx pins that teardown by spying on the driver.
//
// PORTED ARRANGEMENTS, NOT CSS. The numbers below are the web's, transliterated
// from flex CSS to RN flex; they live in one exported table so the shapes have a
// single owner and a reviewer can diff them against the HEEx in one read. Note
// the web has NO dedicated `code` shape — code takes the generic three lines —
// and that parity is deliberate, not an oversight to "fix" here.
//
// Consumer-less by charter ruling D67: mob-rt-s8-progressive-consumer wires it.
import { useEffect, useState } from 'react'
import { Animated, Text, View, type ViewStyle } from 'react-native'

import { useTheme, type Theme } from '../ui/theme'
import { roles, scale } from '../ui/typography'

/* ── the server's vocabulary ────────────────────────────────────────────── */

/** The seven labels `skeleton_label/1` can return, in the server's own order.
 * Drift from this set is drift from the server. */
export const SKELETON_LABELS = ['diagram', 'chart', 'stats', 'table', 'callout', 'code', 'block'] as const

export type SkeletonLabel = (typeof SKELETON_LABELS)[number]

/** The `skeleton_label/1` twin: a known kind maps to itself, everything else —
 * including the empty string and a kind a newer server invents — falls to
 * "block". Total by construction. */
export function skeletonLabel(kind: string): SkeletonLabel {
  return (SKELETON_LABELS as readonly string[]).includes(kind) ? (kind as SkeletonLabel) : 'block'
}

/* ── the arrangements (ported from the HEEx, one owner) ─────────────────── */

/** Geometry for every shape, in one table. Widths given as percentage strings
 * are the web's percentage widths; `flex: 1` stands in for the web's `flex: 1`.
 * No key here is named fontSize/lineHeight — type geometry belongs to
 * src/ui/typography.ts and nothing in this file sets it by hand. */
export const SKELETON_GEOMETRY = {
  /** The dashed honest-degrade box (registry.tsx:43-64, verbatim). */
  box: { borderWidth: 1, borderRadius: 6, padding: 10, marginVertical: 6 },
  /** Space between the "rendering …" label and the shape below it. */
  labelGap: 8,
  /** Corner softening on every bar — the bars are shapes, not text runs. */
  barRadius: 3,
  chart: { band: 64, gap: 6, barWidth: 22, heights: [40, 62, 30, 52, 44, 58] },
  stats: { gap: 8, tileHeight: 52, count: 3 },
  table: { gap: 5, cellHeight: 14, rows: 3, cols: 3 },
  diagram: { band: 56, gap: 10, boxWidth: 88, boxHeight: 34, connectorHeight: 2 },
  callout: { gap: 8, spineWidth: 3, lineGap: 6, barHeight: 12, widths: ['40%', '85%'] },
  generic: { gap: 6, barHeight: 12, widths: ['70%', '90%', '55%'] },
} as const

/** Test seam: every bar carries this testID so a suite can count and measure
 * the shapes without a native host. */
export const SKELETON_BAR_TEST_ID = 'skel-bar'
/** Test seam: the table shape's three row wrappers. */
export const SKELETON_ROW_TEST_ID = 'skel-row'
/** Test seam: the container a shape arranges its bars in — the band whose
 * height/gap/alignment IS half of what distinguishes chart from diagram. */
export const SKELETON_BAND_TEST_ID = 'skel-band'

/* ── the pulse ──────────────────────────────────────────────────────────── */

const PULSE_MIN = 0.35
const PULSE_MAX = 1
const PULSE_MS = 780

/* ── the component ──────────────────────────────────────────────────────── */

export interface StreamSkeletonProps {
  /** The server's block classification. Any string is legal — an unknown one
   * degrades to the generic shape labelled "block". */
  kind: string
  /** The prose the block has emitted so far, if any. Rendered ABOVE the
   * skeleton — never inside it, because text inside a placeholder box reads as
   * the placeholder's content. */
  prose?: string
}

/** The still-forming block: honest label, shaped placeholder, pulsing bars. */
export function StreamSkeleton({ kind, prose }: StreamSkeletonProps) {
  const theme = useTheme()
  const label = skeletonLabel(kind)
  const [pulse] = useState(() => new Animated.Value(PULSE_MAX))

  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, { toValue: PULSE_MIN, duration: PULSE_MS, useNativeDriver: true }),
        Animated.timing(pulse, { toValue: PULSE_MAX, duration: PULSE_MS, useNativeDriver: true }),
      ]),
    )
    loop.start()
    // THE TEARDOWN. Without this line the driver outlives the block it was
    // describing and every finished turn leaves one running behind it.
    return () => loop.stop()
  }, [pulse])

  const shownProse = prose?.trim() ? prose : undefined

  return (
    <View>
      {shownProse === undefined ? null : (
        // `roles.chatBody`, the SETTLED assistant measure — deliberately NOT a
        // notch smaller. This prose is the same sentence flow as the live tail
        // Text directly above it and it becomes a settled paragraph the moment
        // the block closes, so any other rung makes one paragraph change size
        // mid-turn and then change back at settle. The liveness signal is the
        // pulsing box and the "rendering …" label, never the type size.
        <Text style={{ ...roles.chatBody, color: theme.text }}>{shownProse}</Text>
      )}
      <View
        testID={`rendering ${label}`}
        accessibilityLabel={`rendering ${label}`}
        style={{
          borderWidth: SKELETON_GEOMETRY.box.borderWidth,
          borderStyle: 'dashed',
          borderColor: theme.border,
          borderRadius: SKELETON_GEOMETRY.box.borderRadius,
          padding: SKELETON_GEOMETRY.box.padding,
          marginVertical: SKELETON_GEOMETRY.box.marginVertical,
          backgroundColor: theme.surface,
        }}
      >
        <Text
          style={{
            ...scale.xs,
            color: theme.textMuted,
            fontStyle: 'italic',
            marginBottom: SKELETON_GEOMETRY.labelGap,
          }}
        >
          rendering {label}…
        </Text>
        <Shape label={label} pulse={pulse} theme={theme} />
      </View>
    </View>
  )
}

/* ── the shapes ─────────────────────────────────────────────────────────── */

interface BarProps {
  pulse: Animated.Value
  theme: Theme
  style: ViewStyle
}

/** One placeholder bar. A View, never a Text — see law 3. */
function Bar({ pulse, theme, style }: BarProps) {
  return (
    <Animated.View
      testID={SKELETON_BAR_TEST_ID}
      style={[
        { backgroundColor: theme.border, borderRadius: SKELETON_GEOMETRY.barRadius, opacity: pulse },
        style,
      ]}
    />
  )
}

function Shape({ label, pulse, theme }: { label: SkeletonLabel; pulse: Animated.Value; theme: Theme }) {
  const G = SKELETON_GEOMETRY

  if (label === 'chart') {
    return (
      <View
        testID={SKELETON_BAND_TEST_ID}
        style={{ flexDirection: 'row', alignItems: 'flex-end', gap: G.chart.gap, height: G.chart.band }}
      >
        {G.chart.heights.map((h, i) => (
          <Bar key={i} pulse={pulse} theme={theme} style={{ width: G.chart.barWidth, height: h }} />
        ))}
      </View>
    )
  }

  if (label === 'stats') {
    return (
      <View testID={SKELETON_BAND_TEST_ID} style={{ flexDirection: 'row', gap: G.stats.gap }}>
        {Array.from({ length: G.stats.count }, (_, i) => (
          <Bar key={i} pulse={pulse} theme={theme} style={{ flex: 1, height: G.stats.tileHeight }} />
        ))}
      </View>
    )
  }

  if (label === 'table') {
    return (
      <View testID={SKELETON_BAND_TEST_ID} style={{ gap: G.table.gap }}>
        {Array.from({ length: G.table.rows }, (_, r) => (
          <View key={r} testID={SKELETON_ROW_TEST_ID} style={{ flexDirection: 'row', gap: G.table.gap }}>
            {Array.from({ length: G.table.cols }, (_, c) => (
              <Bar key={c} pulse={pulse} theme={theme} style={{ flex: 1, height: G.table.cellHeight }} />
            ))}
          </View>
        ))}
      </View>
    )
  }

  if (label === 'diagram') {
    return (
      <View
        testID={SKELETON_BAND_TEST_ID}
        style={{ flexDirection: 'row', alignItems: 'center', gap: G.diagram.gap, height: G.diagram.band }}
      >
        <Bar
          pulse={pulse}
          theme={theme}
          style={{ width: G.diagram.boxWidth, height: G.diagram.boxHeight }}
        />
        <Bar pulse={pulse} theme={theme} style={{ flex: 1, height: G.diagram.connectorHeight }} />
        <Bar
          pulse={pulse}
          theme={theme}
          style={{ width: G.diagram.boxWidth, height: G.diagram.boxHeight }}
        />
      </View>
    )
  }

  if (label === 'callout') {
    return (
      <View testID={SKELETON_BAND_TEST_ID} style={{ flexDirection: 'row', gap: G.callout.gap }}>
        <Bar pulse={pulse} theme={theme} style={{ width: G.callout.spineWidth, alignSelf: 'stretch' }} />
        <View style={{ flex: 1, gap: G.callout.lineGap }}>
          {G.callout.widths.map((w, i) => (
            <Bar key={i} pulse={pulse} theme={theme} style={{ height: G.callout.barHeight, width: w }} />
          ))}
        </View>
      </View>
    )
  }

  // `code`, `block`, and every unknown kind: the web's generic three lines.
  return (
    <View testID={SKELETON_BAND_TEST_ID} style={{ gap: G.generic.gap }}>
      {G.generic.widths.map((w, i) => (
        <Bar key={i} pulse={pulse} theme={theme} style={{ height: G.generic.barHeight, width: w }} />
      ))}
    </View>
  )
}
