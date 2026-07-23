// App shell: session gate → cascade → three tabs (charter D14).
//
//   no Cloud session          → LoginScreen (device flow)
//   session, no active server → ConnectScreen (fleet cascade + paste)
//   connected                 → Tasks · Chat · Papers tabs
//
// The persisted config (MMKV) is the single source of truth; every
// transition writes it first, then mirrors it into React state — reopening
// the app lands exactly where the user left off (last-location memory).
import { useCallback, useState } from 'react'
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
import { ConnectScreen } from './src/screens/ConnectScreen'
import { LoginScreen, type CloudSession } from './src/screens/LoginScreen'
import { ChatScreen, PapersScreen } from './src/screens/StubScreens'
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

  const connection = connectionFromConfig(config)

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
          {tab === 'chat' && <ChatScreen />}
          {tab === 'papers' && <PapersScreen />}
        </View>
        <TabBar active={tab} onSelect={setTab} />
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
