// App shell: session gate → cascade → three tabs (charter D14).
//
//   no Cloud session          → LoginScreen (device flow)
//   session, no active server → ConnectScreen (fleet cascade + paste)
//   connected                 → Tasks · Chat · Papers tabs
//
// The persisted config (MMKV) is the single source of truth; every
// transition writes it first, then mirrors it into React state — reopening
// the app lands exactly where the user left off (last-location memory).
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { StyleSheet, Text, View } from 'react-native'
import { StatusBar } from 'expo-status-bar'

import type { ConnectTarget } from './src/cascade/fleetPick'
import type { StoredConfig } from './src/cascade/knownServers'
import { connectionFromConfig } from './src/api/instance'
import {
  clearConfig,
  hasActiveServer,
  hasCloudSession,
  loadConfig,
  rememberAndSave,
  saveCloudSession,
} from './src/state/appConfig'
import { useChatRollup } from './src/chat/useChatRollup'
import { pushNotice, usePushRegistration } from './src/push'
import { ChatScreen } from './src/screens/ChatScreen'
import { ConnectScreen } from './src/screens/ConnectScreen'
import { LoginScreen, type CloudSession } from './src/screens/LoginScreen'
import { PapersScreen } from './src/screens/PapersScreen'
import { TasksScreen } from './src/screens/TasksScreen'
import { TabBar, type TabKey } from './src/ui/TabBar'
import { haptic, needsYouRisingEdge } from './src/ui/haptics'
import { useTheme } from './src/ui/theme'
import { scale } from './src/ui/typography'

export default function App() {
  const theme = useTheme()
  const [config, setConfig] = useState<StoredConfig>(() => loadConfig())
  const [tab, setTab] = useState<TabKey>('tasks')

  const onLoggedIn = useCallback((session: CloudSession) => {
    setConfig(saveCloudSession({ url: session.url, token: session.token, teamId: session.teamId }))
  }, [])

  const onConnected = useCallback((target: ConnectTarget) => {
    setConfig(
      rememberAndSave({
        server: target.server,
        token: target.token,
        name: target.name,
        instanceId: target.instanceId || undefined,
        team: target.team || undefined,
        dataset: 'production',
      }),
    )
  }, [])

  const onSignOut = useCallback(() => {
    clearConfig()
    setConfig({})
    setTab('tasks')
  }, [])

  // Memoized on the config object: connection identity must be STABLE across
  // re-renders — every consumer keys effects on it (the Tasks tab's client +
  // listen() stream, the chat session store, the rollup poll). A fresh object
  // per render would resubscribe streams on every render, and the rollup
  // poll's own setState would then feed that loop.
  const connection = useMemo(() => connectionFromConfig(config), [config])

  // Needs-you badge (ratified R3): blocked sessions from GET /v1/chat/rollup.
  //
  // The feed carries the count AND its standing: once the poll has failed
  // often enough (or the last confirmed answer is old enough) the shell stops
  // vouching for the number, and the tab bar paints it as last-known instead
  // of as a reading. The judgement lives here because the shell owns the feed;
  // TabBar owns only the two paints.
  const feed = useChatRollup(connection)
  const rollup = feed.rollup
  const chatBadge = useMemo(
    () => ({ count: rollup?.counts.blocked ?? 0, confirmed: feed.freshness === 'confirmed' }),
    [rollup, feed.freshness],
  )

  // needsYou haptic (charter D33) — the app's ONE stage-1 haptic call site.
  // The shell owns badge derivation, so the shell owns the edge; TabBar stays
  // pure-render. Fires only on the RISING edge of counts.blocked (the pure,
  // jest-pinned needsYouRisingEdge): initial load, equal polls, decreases and
  // a server switch (prev resets below) are all silent — reopening the app
  // onto an already-blocked board must not buzz.
  const prevBlocked = useRef<number | undefined>(undefined)
  useEffect(() => {
    // A new connection is a fresh board: its first rollup reads as initial.
    prevBlocked.current = undefined
  }, [connection])
  useEffect(() => {
    if (rollup === undefined) return // unknown is not 0 — no edge to judge yet
    const next = rollup.counts.blocked
    if (needsYouRisingEdge(prevBlocked.current, next)) haptic('needsYou')
    prevBlocked.current = next
  }, [rollup])

  // Needs-you PUSH (charter D15) — the app's one registration call site.
  //
  // Keyed on the CLOUD session, not the instance connection: a device belongs
  // to the user, and the relay fans out to a team's members regardless of which
  // instance they are currently looking at. Memoized for the same reason
  // `connection` is — a fresh object per render would re-key the hook's effect.
  //
  // Today this resolves to `{status: 'unavailable', reason: 'module-missing'}`
  // on every launch and writes nothing: `expo-notifications`, the platform
  // entitlements and the APNs/FCM credentials are one human gate, documented in
  // cloud/lib/barkpark_cloud/push/adapters/not_configured.ex. That is the
  // severable state working as designed — no row, nothing fires, nothing to
  // flip off. When the gate opens, this line already registers.
  const cloudSession = useMemo(
    () =>
      config.cloudUrl && config.cloudToken
        ? { url: config.cloudUrl, token: config.cloudToken }
        : undefined,
    [config.cloudUrl, config.cloudToken],
  )
  // The verdict is RENDERED, not discarded (last-mile wave): registerDevice
  // already refuses to report `registered` without a row id, and an app that
  // then throws that verdict away would keep a 401/422/429 as silent as a
  // healthy launch — the phone would simply never buzz and never say why.
  const pushLine = pushNotice(usePushRegistration(cloudSession))

  let body
  if (!hasCloudSession(config)) {
    body = <LoginScreen onLoggedIn={onLoggedIn} />
  } else if (!hasActiveServer(config) || connection === undefined) {
    body = <ConnectScreen config={config} onConnected={onConnected} onSignOut={onSignOut} />
  } else {
    body = (
      <View style={styles.shell}>
        <View style={styles.content}>
          {tab === 'tasks' && <TasksScreen connection={connection} />}
          {tab === 'chat' && <ChatScreen connection={connection} claim={config} />}
          {tab === 'papers' && <PapersScreen connection={connection} />}
        </View>
        {pushLine !== undefined && (
          <Text style={[styles.pushNotice, { color: theme.textMuted, borderTopColor: theme.border }]}>
            {pushLine}
          </Text>
        )}
        <TabBar active={tab} onSelect={setTab} badges={{ chat: chatBadge }} />
      </View>
    )
  }

  return (
    <View style={[styles.root, { backgroundColor: theme.bg }]}>
      <StatusBar style="auto" />
      {body}
    </View>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  shell: { flex: 1 },
  content: { flex: 1 },
  pushNotice: {
    ...scale.xs,
    borderTopWidth: 1,
    paddingHorizontal: 16,
    paddingVertical: 6,
    textAlign: 'center',
  },
})
