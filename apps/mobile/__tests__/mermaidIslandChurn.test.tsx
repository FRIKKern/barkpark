// MermaidIsland churn/offline hardening (mob-zb-bl-island-churn-offline) —
// the COMPONENT mounted with react-test-renderer and the WebView mocked as a
// props-capturing ELEMENT (not null), so the height/message/watchdog wiring
// actually runs. The pure-function rings stay in mermaidIsland.test.ts.
//
// NAMED MUTANTS each probe kills:
//   • delete-the-memo-read      → the remount probe reds (paints 220 again)
//   • delete-the-memo-write     → same probe reds from the other side
//   • delete-the-watchdog       → the captive-portal probe reds (mute box
//                                 forever, no placeholder)
//   • watchdog-ignores-settle   → the disarm probe reds (a rendered diagram
//                                 later degrades to the placeholder)
//   • delete-the-loading-label  → the working-state probe reds
import { act, create, type ReactTestRenderer } from 'react-test-renderer'

import {
  MermaidIsland,
  heightMemoKey,
  lastKnownHeight,
  resetHeightMemoForTesting,
} from '../src/papers/portabledoc/MermaidIsland'
import type { Theme } from '../src/ui/theme'

// (hoisted) The mock must be an ELEMENT that exposes its props — the churn
// probes drive onMessage and read style.height, which a `() => null` stub
// structurally cannot support.
const mockWebViewProps: Record<string, unknown>[] = []
jest.mock('react-native-webview', () => {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { View } = require('react-native')
  return {
    WebView: (props: Record<string, unknown>) => {
      mockWebViewProps.push(props)
      return <View testID="mermaid-webview" />
    },
  }
})

const theme = {
  isDark: false,
  border: '#ddd',
  surface: '#fff',
  textMuted: '#888',
} as unknown as Theme

const SOURCE = 'graph TD; A-->B'

/** The most recent WebView mount's props. */
function webViewProps(): Record<string, unknown> {
  const props = mockWebViewProps[mockWebViewProps.length - 1]
  if (props === undefined) throw new Error('no WebView mounted')
  return props
}

function paintedHeight(): number {
  const style = webViewProps().style as { height: number }
  return style.height
}

function postHeight(px: number): void {
  const onMessage = webViewProps().onMessage as (ev: {
    nativeEvent: { data: string }
  }) => void
  act(() => {
    onMessage({ nativeEvent: { data: JSON.stringify({ kind: 'height', px }) } })
  })
}

/** Every string leaf the mounted tree paints. */
function textOf(tree: ReactTestRenderer): string {
  const out: string[] = []
  const walk = (node: unknown): void => {
    if (node === null || node === undefined || typeof node === 'boolean') return
    if (typeof node === 'string' || typeof node === 'number') {
      out.push(String(node))
      return
    }
    if (Array.isArray(node)) {
      for (const child of node) walk(child)
      return
    }
    walk((node as { children?: unknown }).children ?? null)
  }
  walk(tree.toJSON())
  return out.join(' ')
}

function mount(source = SOURCE): ReactTestRenderer {
  let tree: ReactTestRenderer
  act(() => {
    tree = create(<MermaidIsland source={source} theme={theme} />)
  })
  return tree!
}

beforeEach(() => {
  jest.useFakeTimers()
  mockWebViewProps.length = 0
  resetHeightMemoForTesting()
})

afterEach(() => {
  jest.clearAllTimers()
  jest.useRealTimers()
})

describe('defect 1 — height survives unmount/remount', () => {
  it('a remount paints the last-known height, not the 220 estimate (mutants: delete-the-memo-read/write)', () => {
    const first = mount()
    try {
      expect(paintedHeight()).toBe(220) // cold: nothing known yet
      postHeight(640)
      expect(paintedHeight()).toBe(656) // 640 + 16 padding — the probe's exact churn numbers
      expect(lastKnownHeight(heightMemoKey(SOURCE, theme))).toBe(656)
    } finally {
      act(() => first.unmount())
    }

    // The FlatList scroll-back: a brand-new mount of the same diagram.
    const second = mount()
    try {
      expect(paintedHeight()).toBe(656) // NOT 220 — no layout jump on revisit
    } finally {
      act(() => second.unmount())
    }
  })

  it('the html memo is warm across state-driven re-renders — the WebView document is never reloaded mid-mount', () => {
    // A reload is what re-fetches the CDN, and RN WebView reloads when the
    // source object's html CHANGES. Same html identity across the height
    // re-render = no reload = no re-fetch while mounted.
    const tree = mount()
    try {
      const before = (webViewProps().source as { html: string }).html
      postHeight(640) // state change → re-render
      const after = (webViewProps().source as { html: string }).html
      expect(after).toBe(before)
    } finally {
      act(() => tree.unmount())
    }
  })
})

describe('defect 2 — the island says it is working', () => {
  it('paints "Loading diagram…" until the first message, then drops it (mutant: delete-the-loading-label)', () => {
    const tree = mount()
    try {
      expect(textOf(tree)).toContain('Loading diagram…')
      postHeight(300)
      expect(textOf(tree)).not.toContain('Loading diagram…')
    } finally {
      act(() => tree.unmount())
    }
  })
})

describe('defect 3 — the captive-portal watchdog', () => {
  it('a mount that never hears from the island degrades to the failed placeholder at ~4s (mutant: delete-the-watchdog)', () => {
    const tree = mount()
    try {
      act(() => {
        jest.advanceTimersByTime(4001)
      })
      const text = textOf(tree)
      expect(text).toContain('could not render')
      expect(text).toContain(SOURCE) // the verbatim source, never a blank hole
    } finally {
      act(() => tree.unmount())
    }
  })

  it('a height message DISARMS it — a rendered diagram never later degrades (mutant: watchdog-ignores-settle)', () => {
    const tree = mount()
    try {
      postHeight(300)
      act(() => {
        jest.advanceTimersByTime(60_000)
      })
      expect(textOf(tree)).not.toContain('could not render')
      expect(paintedHeight()).toBe(316)
    } finally {
      act(() => tree.unmount())
    }
  })

  it('an explicit error message fails immediately without waiting out the watchdog', () => {
    const tree = mount()
    try {
      const onMessage = webViewProps().onMessage as (ev: { nativeEvent: { data: string } }) => void
      act(() => {
        onMessage({ nativeEvent: { data: JSON.stringify({ kind: 'error', why: 'cdn' }) } })
      })
      expect(textOf(tree)).toContain('could not render')
    } finally {
      act(() => tree.unmount())
    }
  })
})

describe('the memo stays honest', () => {
  it('dark and light heights do not cross-pollinate — the key carries the theme', () => {
    expect(heightMemoKey(SOURCE, theme)).not.toBe(
      heightMemoKey(SOURCE, { ...theme, isDark: true } as unknown as Theme),
    )
  })

  it('a clamped (truncated) report is remembered at the clamp, so the remount does not jump past the guard', () => {
    const tree = mount()
    try {
      postHeight(20_000)
      expect(paintedHeight()).toBe(8000)
      expect(textOf(tree)).toContain('Diagram truncated')
      expect(lastKnownHeight(heightMemoKey(SOURCE, theme))).toBe(8000)
    } finally {
      act(() => tree.unmount())
    }
  })
})
