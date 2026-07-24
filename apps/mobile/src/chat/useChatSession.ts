// The thin React binding for ChatSessionStore — the store does the work
// (reducer dispatch, IO effects, SSE lifecycle); this hook only constructs it
// per (connection, session, attempt) and subscribes the component to its
// snapshots.
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from 'react'

import type { InstanceConnection } from '../api/instance'
import { ChatSessionStore, type SessionSnapshot } from './sessionStore'

export interface ChatSessionHandle extends SessionSnapshot {
  send: (content: string) => void
  interrupt: () => void
  answer: (requestId: string, decision: 'allow' | 'deny') => void
  retry: () => void
}

export function useChatSession(
  connection: InstanceConnection,
  sessionId: string,
): ChatSessionHandle {
  const [attempt, setAttempt] = useState(0)
  const store = useMemo(() => {
    // attempt is the retry trigger: a bump constructs a fresh store.
    void attempt
    return new ChatSessionStore(connection, sessionId)
  }, [connection, sessionId, attempt])

  useEffect(() => {
    store.start()
    return () => store.stop()
  }, [store])

  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot)

  const send = useCallback((content: string) => store.send(content), [store])
  const interrupt = useCallback(() => store.interrupt(), [store])
  const answer = useCallback(
    (requestId: string, decision: 'allow' | 'deny') => store.answer(requestId, decision),
    [store],
  )
  const retry = useCallback(() => setAttempt((a) => a + 1), [])

  return { ...snapshot, send, interrupt, answer, retry }
}
