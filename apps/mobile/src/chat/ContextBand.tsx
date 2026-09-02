// The chat session screen's CONNECTION HEADER (chat-local-cloud-context-w3,
// criterion 2). WHICH execution host runs this session, against WHICH Barkpark
// server, in WHICH workspace / project / dataset, out of WHICH repository root.
//
// It is the twin of the CLI's `contextLines` (internal/chat/render.go) and of
// the Studio band (`chat-context-band` in chat_live.ex), and it renders exactly
// what `context.ts` resolved — a field's value, its typed absence marker, and
// the disagreement report riding after either. This file makes NO decision
// about what any field says; putting one here would be a fourth answer to a
// question three surfaces already agree on.
//
// Every segment carries `testID={'chat-context-' + name}` so a guard addresses
// a field BY NAME. A positional read of a six-item row is how a reordered band
// turns into a silently wrong test.
import { StyleSheet, Text, View } from 'react-native'

import { fieldDisplay, type ContextIdentity } from './context'
import type { Theme } from '../ui/theme'
import { scale } from '../ui/typography'

/** The prefix a disagreeing field wears. Exported because the guard asserts on
 * it: a ⚠ that quietly stopped rendering would leave a wrong connection
 * reading as a right one, which is the whole failure this band exists to
 * prevent. */
export const MISMATCH_MARK = '⚠'

/** The full text of one segment, as the eye reads it: the marker (when the
 * field disagrees with itself), the field's name, and its display.
 *
 * Exported and pure so the guard reads the SAME string the band paints rather
 * than a re-assembled look-alike. A test that builds its own expected label
 * cannot catch a band that stopped rendering the name. */
export function contextSegmentText(name: string, display: string, mismatch: boolean): string {
  return `${mismatch ? `${MISMATCH_MARK} ` : ''}${name} ${display}`
}

export function ContextBand({
  identity,
  theme,
}: {
  identity: ContextIdentity
  theme: Theme
}): React.ReactElement {
  return (
    <View testID="chat-context-band" style={[styles.band, { borderBottomColor: theme.border }]}>
      {identity.fields.map((f) => (
        <Text
          key={f.name}
          testID={`chat-context-${f.name}`}
          numberOfLines={1}
          style={[styles.segment, { color: f.mismatch ? theme.warn : theme.textMuted }]}
        >
          {contextSegmentText(f.name, fieldDisplay(f), f.mismatch)}
        </Text>
      ))}
    </View>
  )
}

const styles = StyleSheet.create({
  // Wraps rather than scrolls: a horizontally-scrolling identity band is one
  // whose most alarming field can be off-screen, and an alarm you have to swipe
  // to is not an alarm.
  band: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    columnGap: 12,
    rowGap: 2,
    paddingHorizontal: 16,
    paddingBottom: 6,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  segment: { ...scale.micro },
})
