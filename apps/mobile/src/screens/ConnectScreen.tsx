// The cascade: server → workspace → project → dataset with single-option
// auto-select (charter D14). This screen walks the SERVER leg — the fleet
// pick transliterated from cloudFleetPick: n==0 honest empty state, n==1
// auto-connect with no picker, n>=2 a picker; member mint → paste fallback
// (cloudNoAdminToken idiom, the day-1 credential path). Workspace/project/
// dataset default to the instance's flat surface + 'production' for wave 1
// (the deeper walk arrives with real tenancy needs).
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native'

import { createCloudClient, type CloudBarkpark, type CloudClient } from '../cloud/api'
import {
  connectFromPaste,
  decideFleet,
  resolveTarget,
  type ConnectTarget,
  type PasteRequest,
} from '../cascade/fleetPick'
import type { StoredConfig } from '../cascade/knownServers'
import { useTheme } from '../ui/theme'

type ConnectState =
  | { phase: 'loading' }
  | { phase: 'empty' }
  | { phase: 'choose'; list: CloudBarkpark[] }
  | { phase: 'resolving'; name: string }
  | { phase: 'paste'; request: PasteRequest; token: string; submitting: boolean }
  | { phase: 'provisioning'; name: string }
  | { phase: 'error'; message: string }

export function ConnectScreen({
  config,
  onConnected,
  onSignOut,
}: {
  config: StoredConfig
  onConnected: (target: ConnectTarget) => void
  onSignOut: () => void
}) {
  const theme = useTheme()
  const [state, setState] = useState<ConnectState>({ phase: 'loading' })
  const [attempt, setAttempt] = useState(0)

  const client: CloudClient = useMemo(
    () => createCloudClient({ baseUrl: config.cloudUrl, token: config.cloudToken }),
    [config.cloudUrl, config.cloudToken],
  )

  const resolve = useCallback(
    async (cloudClient: CloudClient, picked: CloudBarkpark) => {
      setState({ phase: 'resolving', name: picked.name })
      try {
        const outcome = await resolveTarget(cloudClient, picked)
        switch (outcome.kind) {
          case 'connected':
            onConnected(outcome.target)
            return
          case 'paste':
            setState({ phase: 'paste', request: outcome.request, token: '', submitting: false })
            return
          case 'provisioning':
            setState({ phase: 'provisioning', name: outcome.name })
            return
        }
      } catch {
        setState({ phase: 'error', message: `Could not connect to “${picked.name}”.` })
      }
    },
    [onConnected],
  )

  // The fleet load lives in the effect; every setState happens AFTER an
  // await so renders never cascade synchronously. `attempt` is the re-run
  // trigger the retry handlers bump.
  useEffect(() => {
    let alive = true
    ;(async () => {
      let list: CloudBarkpark[]
      try {
        list = await client.listAllBarkparks()
      } catch {
        if (alive) {
          setState({ phase: 'error', message: 'Could not load your Barkparks. Check your connection and try again.' })
        }
        return
      }
      if (!alive) return
      const decision = decideFleet(list)
      switch (decision.kind) {
        case 'empty':
          setState({ phase: 'empty' })
          return
        case 'auto':
          // Only Barkpark in the fleet — auto-select, no picker (charter D14).
          await resolve(client, decision.picked)
          return
        case 'choose':
          setState({ phase: 'choose', list: decision.list })
          return
      }
    })()
    return () => {
      alive = false
    }
  }, [client, resolve, attempt])

  const loadFleet = useCallback(() => {
    setState({ phase: 'loading' })
    setAttempt((a) => a + 1)
  }, [])

  const submitPaste = useCallback(() => {
    if (state.phase !== 'paste') return
    const token = state.token.trim()
    if (token === '') return
    setState({ ...state, submitting: true })
    onConnected(connectFromPaste(state.request, token))
  }, [state, onConnected])

  return (
    <View style={[styles.root, { backgroundColor: theme.bg }]}>
      <Text style={[styles.heading, { color: theme.text }]}>Connect</Text>

      {state.phase === 'loading' && (
        <View style={styles.centerBlock}>
          <ActivityIndicator color={theme.accent} />
          <Text style={[styles.muted, { color: theme.textMuted }]}>Loading your Barkparks…</Text>
        </View>
      )}

      {state.phase === 'empty' && (
        <View style={styles.centerBlock}>
          <Text style={[styles.body, { color: theme.text }]}>
            You&apos;re signed in — but this account has no Barkparks yet.
          </Text>
          <Text style={[styles.muted, { color: theme.textMuted }]}>
            Launch one from the Cloud console or the bp CLI, then pull to retry here.
          </Text>
          <Pressable accessibilityRole="button" onPress={loadFleet}>
            <Text style={[styles.link, { color: theme.accent }]}>Check again</Text>
          </Pressable>
        </View>
      )}

      {state.phase === 'choose' && (
        <FlatList
          data={state.list}
          keyExtractor={(b) => b.id}
          contentContainerStyle={styles.listContent}
          renderItem={({ item }) => (
            <Pressable
              accessibilityRole="button"
              onPress={() => resolve(client, item)}
              style={({ pressed }) => [
                styles.serverRow,
                { backgroundColor: theme.surface, borderColor: theme.border, opacity: pressed ? 0.8 : 1 },
              ]}
            >
              <Text style={[styles.serverName, { color: theme.text }]}>{item.name}</Text>
              <Text style={[styles.muted, { color: theme.textMuted }]}>
                {item.team?.name ? `${item.team.name} · ` : ''}
                {item.url || item.host || 'no address yet'}
              </Text>
            </Pressable>
          )}
        />
      )}

      {state.phase === 'resolving' && (
        <View style={styles.centerBlock}>
          <ActivityIndicator color={theme.accent} />
          <Text style={[styles.muted, { color: theme.textMuted }]}>Connecting to “{state.name}”…</Text>
        </View>
      )}

      {state.phase === 'paste' && (
        <View style={styles.centerBlock}>
          <Text style={[styles.body, { color: theme.text }]}>
            “{state.request.barkpark.name}” needs a token to connect.
          </Text>
          <Text style={[styles.muted, { color: theme.textMuted }]}>
            Paste an API token for {state.request.server}. Ask a team owner if you don&apos;t have one.
          </Text>
          <TextInput
            accessibilityLabel="API token"
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
            placeholder="Paste token"
            placeholderTextColor={theme.textMuted}
            value={state.token}
            onChangeText={(token) => setState({ ...state, token })}
            style={[styles.input, { color: theme.text, borderColor: theme.border, backgroundColor: theme.surface }]}
          />
          <Pressable
            accessibilityRole="button"
            disabled={state.token.trim() === '' || state.submitting}
            onPress={submitPaste}
            style={({ pressed }) => [
              styles.primaryButton,
              {
                backgroundColor: theme.accent,
                opacity: state.token.trim() === '' || state.submitting ? 0.5 : pressed ? 0.85 : 1,
              },
            ]}
          >
            <Text style={[styles.primaryButtonText, { color: theme.accentText }]}>Connect</Text>
          </Pressable>
          <Pressable accessibilityRole="button" onPress={loadFleet}>
            <Text style={[styles.link, { color: theme.textMuted }]}>Back</Text>
          </Pressable>
        </View>
      )}

      {state.phase === 'provisioning' && (
        <View style={styles.centerBlock}>
          <Text style={[styles.body, { color: theme.text }]}>“{state.name}” has no address yet — it&apos;s still provisioning.</Text>
          <Pressable accessibilityRole="button" onPress={loadFleet}>
            <Text style={[styles.link, { color: theme.accent }]}>Check again</Text>
          </Pressable>
        </View>
      )}

      {state.phase === 'error' && (
        <View style={styles.centerBlock}>
          <Text style={[styles.body, { color: theme.danger }]}>{state.message}</Text>
          <Pressable accessibilityRole="button" onPress={loadFleet}>
            <Text style={[styles.link, { color: theme.accent }]}>Try again</Text>
          </Pressable>
        </View>
      )}

      <Pressable accessibilityRole="button" onPress={onSignOut} style={styles.signOut}>
        <Text style={[styles.link, { color: theme.textMuted }]}>Sign out</Text>
      </Pressable>
    </View>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1, padding: 24, paddingTop: 72 },
  heading: { fontSize: 26, fontWeight: '700', marginBottom: 20 },
  centerBlock: { alignItems: 'center', gap: 12, marginTop: 32, paddingHorizontal: 8 },
  listContent: { gap: 10 },
  serverRow: { borderWidth: 1, borderRadius: 12, padding: 14, gap: 4 },
  serverName: { fontSize: 16, fontWeight: '600' },
  body: { fontSize: 15, textAlign: 'center', lineHeight: 21 },
  muted: { fontSize: 13, textAlign: 'center', lineHeight: 19 },
  link: { fontSize: 14, textDecorationLine: 'underline' },
  input: {
    alignSelf: 'stretch',
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 11,
    fontSize: 15,
  },
  primaryButton: { paddingHorizontal: 22, paddingVertical: 12, borderRadius: 10 },
  primaryButtonText: { fontSize: 15, fontWeight: '600' },
  signOut: { alignItems: 'center', paddingVertical: 16 },
})
