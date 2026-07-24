// Papers stub (charter D14: NO paper reader until the renderer spike's
// verdict — the Chat stub graduated to the wave-2 full floor, ChatScreen.tsx).
// Honest placeholder: it says what's coming instead of pretending to be an
// empty state.
import { StyleSheet, Text, View } from 'react-native'

import { useTheme } from '../ui/theme'

function Stub({ title, body }: { title: string; body: string }) {
  const theme = useTheme()
  return (
    <View style={[styles.root, { backgroundColor: theme.bg }]}>
      <Text style={[styles.title, { color: theme.text }]}>{title}</Text>
      <Text style={[styles.body, { color: theme.textMuted }]}>{body}</Text>
    </View>
  )
}

export function PapersScreen() {
  return (
    <Stub
      title="Papers"
      body="The premium cached paper reader arrives once the wave-1 renderer spike returns its verdict."
    />
  )
}

const styles = StyleSheet.create({
  root: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 32, gap: 10 },
  title: { fontSize: 22, fontWeight: '700' },
  body: { fontSize: 14, textAlign: 'center', lineHeight: 20, maxWidth: 320 },
})
