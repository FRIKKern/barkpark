// Cloud device-flow login (charter D14): the phone twin of `bp login`'s
// copy-a-link flow. Honest states all the way: idle → starting → waiting
// (code + approve link + live polling) → approved / expired / denied /
// transport error, each with its own affordance — never a spinner dead end.
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  ActivityIndicator,
  Linking,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native'

import { createCloudClient, DEFAULT_CLOUD_URL } from '../cloud/api'
import { startDeviceFlow, type DeviceFlowHandle } from '../cloud/deviceFlow'
import { useTheme } from '../ui/theme'
import { roles, scale } from '../ui/typography'

export interface CloudSession {
  url: string
  token: string
  teamId: string
}

type LoginState =
  | { phase: 'idle' }
  | { phase: 'starting' }
  | { phase: 'waiting'; userCode: string; approveUrl: string }
  | { phase: 'error'; message: string }

export function LoginScreen({ onLoggedIn }: { onLoggedIn: (session: CloudSession) => void }) {
  const theme = useTheme()
  const [state, setState] = useState<LoginState>({ phase: 'idle' })
  const flowRef = useRef<DeviceFlowHandle | undefined>(undefined)

  // Back out of a pending flow when the screen unmounts.
  useEffect(() => () => flowRef.current?.cancel(), [])

  const begin = useCallback(async () => {
    setState({ phase: 'starting' })
    const client = createCloudClient({ baseUrl: DEFAULT_CLOUD_URL })
    let handle: DeviceFlowHandle
    try {
      handle = await startDeviceFlow(client, 'Barkpark mobile')
    } catch {
      setState({ phase: 'error', message: 'Could not reach Barkpark Cloud. Check your connection and try again.' })
      return
    }
    flowRef.current = handle
    const approveUrl = handle.session.verificationUriComplete || handle.session.verificationUri
    setState({ phase: 'waiting', userCode: handle.session.userCode, approveUrl })

    try {
      const outcome = await handle.outcome
      switch (outcome.kind) {
        case 'approved':
          onLoggedIn({ url: DEFAULT_CLOUD_URL, token: outcome.token, teamId: outcome.teamId })
          return
        case 'expired':
          setState({ phase: 'error', message: 'The sign-in code expired before it was approved. Start again to get a fresh code.' })
          return
        case 'denied':
          setState({ phase: 'error', message: 'Sign-in was declined on the approval page.' })
          return
        case 'cancelled':
          setState({ phase: 'idle' })
          return
      }
    } catch {
      setState({ phase: 'error', message: 'Lost the connection while waiting for approval. Try again.' })
    }
  }, [onLoggedIn])

  return (
    <View style={[styles.root, { backgroundColor: theme.bg }]}>
      <Text style={[styles.brand, { color: theme.text }]}>Barkpark</Text>
      <Text style={[styles.tagline, { color: theme.textMuted }]}>
        Tasks, chat and papers for your team — sign in with Barkpark Cloud.
      </Text>

      {state.phase === 'idle' && (
        <Pressable
          accessibilityRole="button"
          onPress={begin}
          style={({ pressed }) => [
            styles.primaryButton,
            { backgroundColor: theme.accent, opacity: pressed ? 0.85 : 1 },
          ]}
        >
          <Text style={[styles.primaryButtonText, { color: theme.accentText }]}>Sign in with Barkpark Cloud</Text>
        </Pressable>
      )}

      {state.phase === 'starting' && (
        <View style={styles.centerBlock}>
          <ActivityIndicator color={theme.accent} />
          <Text style={[styles.statusText, { color: theme.textMuted }]}>Contacting Barkpark Cloud…</Text>
        </View>
      )}

      {state.phase === 'waiting' && (
        <View style={styles.centerBlock}>
          <Text style={[styles.codeLabel, { color: theme.textMuted }]}>Your sign-in code</Text>
          <Text
            accessibilityLabel={`Sign in code ${state.userCode}`}
            style={[styles.code, { color: theme.text, borderColor: theme.border, backgroundColor: theme.surface }]}
          >
            {state.userCode}
          </Text>
          <Pressable
            accessibilityRole="button"
            onPress={() => Linking.openURL(state.approveUrl)}
            style={({ pressed }) => [
              styles.primaryButton,
              { backgroundColor: theme.accent, opacity: pressed ? 0.85 : 1 },
            ]}
          >
            <Text style={[styles.primaryButtonText, { color: theme.accentText }]}>Approve in browser</Text>
          </Pressable>
          <View style={styles.pollRow}>
            <ActivityIndicator size="small" color={theme.textMuted} />
            <Text style={[styles.statusText, { color: theme.textMuted }]}>Waiting for approval…</Text>
          </View>
          <Pressable
            accessibilityRole="button"
            onPress={() => {
              flowRef.current?.cancel()
            }}
          >
            <Text style={[styles.linkText, { color: theme.textMuted }]}>Cancel</Text>
          </Pressable>
        </View>
      )}

      {state.phase === 'error' && (
        <View style={styles.centerBlock}>
          <Text style={[styles.errorText, { color: theme.danger }]}>{state.message}</Text>
          <Pressable
            accessibilityRole="button"
            onPress={begin}
            style={({ pressed }) => [
              styles.primaryButton,
              { backgroundColor: theme.accent, opacity: pressed ? 0.85 : 1 },
            ]}
          >
            <Text style={[styles.primaryButtonText, { color: theme.accentText }]}>Try again</Text>
          </Pressable>
        </View>
      )}
    </View>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24, gap: 16 },
  brand: { ...roles.brandWordmark, fontWeight: '700', letterSpacing: -0.5 },
  tagline: { ...scale.md, textAlign: 'center', maxWidth: 300 },
  centerBlock: { alignItems: 'center', gap: 14, marginTop: 8 },
  primaryButton: { paddingHorizontal: 22, paddingVertical: 13, borderRadius: 10 },
  primaryButtonText: { ...scale.lg, fontWeight: '600' },
  codeLabel: { ...scale.sm, textTransform: 'uppercase', letterSpacing: 1 },
  code: {
    ...roles.deviceCode,
    fontWeight: '700',
    letterSpacing: 3,
    paddingHorizontal: 18,
    paddingVertical: 10,
    borderRadius: 10,
    borderWidth: 1,
    overflow: 'hidden',
  },
  pollRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  statusText: { ...scale.base },
  linkText: { ...scale.base, textDecorationLine: 'underline' },
  errorText: { ...scale.md, textAlign: 'center', maxWidth: 300 },
})
