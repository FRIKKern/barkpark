// Chat + Papers stubs (charter D14: three STUB tabs, NO paper reader — the
// renderer bet is quarantined in mob-w1-webview-spike). Honest placeholders:
// they say what's coming instead of pretending to be empty states.
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

export function ChatScreen() {
  return (
    <Stub
      title="Chat"
      body="The full chat floor — send, stream, interrupt, approve and deny — arrives in wave 2 as the third sibling client of /v1/chat."
    />
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
