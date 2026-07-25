// App shell: session gate → cascade → three tabs (charter D14).
//
//   no Cloud session          → LoginScreen (device flow)
//   session, no active server → ConnectScreen (fleet cascade + paste)
//   connected                 → Tasks · Chat · Papers tabs
//
// The persisted config (MMKV) is the single source of truth; every
// transition writes it first, then mirrors it into React state — reopening
// the app lands exactly where the user left off (last-location memory).
import { useCallback, useMemo, useState } from 'react'
import { StyleSheet, View } from 'react-native'
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
import { ChatScreen } from './src/screens/ChatScreen'
import { ConnectScreen } from './src/screens/ConnectScreen'
import { LoginScreen, type CloudSession } from './src/screens/LoginScreen'
import { PapersScreen } from './src/screens/PapersScreen'
import { TasksScreen } from './src/screens/TasksScreen'
import { TabBar, type TabKey } from './src/ui/TabBar'
import { useTheme } from './src/ui/theme'

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
  const rollup = useChatRollup(connection)
  const chatBadge = rollup?.counts.blocked ?? 0

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
          {tab === 'chat' && <ChatScreen connection={connection} />}
          {tab === 'papers' && <PapersScreen connection={connection} />}
        </View>
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
})
