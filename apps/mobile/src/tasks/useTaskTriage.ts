// The thin React binding for TriageStore — the store does the work (reducer
// dispatch, /v1/tasks IO); this hook only constructs it per (connection, doc)
// and subscribes the component to its snapshots. Same shape as
// useChatSession.
import { useCallback, useEffect, useMemo, useSyncExternalStore } from 'react'

import type { InstanceConnection } from '../api/instance'
import { apiFor, TriageStore } from './triageStore'
import type { TriageState } from './triage'
import { getWorkerId } from './workerId'

export interface TaskTriageHandle {
  state: TriageState
  refresh: () => void
  stamp: (criterion: number, met: boolean, text: string) => void
  pulse: (text: string) => void
  claim: () => void
  release: () => void
  dismissNotice: () => void
}

export function useTaskTriage(
  connection: InstanceConnection,
  docId: string,
): TaskTriageHandle {
  const store = useMemo(
    () => new TriageStore(apiFor(connection), docId, getWorkerId()),
    [connection, docId],
  )

  useEffect(() => {
    store.start()
    return () => store.stop()
  }, [store])

  const state = useSyncExternalStore(store.subscribe, store.getSnapshot)

  const refresh = useCallback(() => store.refresh(), [store])
  const stamp = useCallback(
    (criterion: number, met: boolean, text: string) => store.stamp(criterion, met, text),
    [store],
  )
  const pulse = useCallback((text: string) => store.pulse(text), [store])
  const claim = useCallback(() => store.claim(), [store])
  const release = useCallback(() => store.release(), [store])
  const dismissNotice = useCallback(() => store.dismissNotice(), [store])

  return { state, refresh, stamp, pulse, claim, release, dismissNotice }
}
