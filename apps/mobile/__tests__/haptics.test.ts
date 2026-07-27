// Haptic vocabulary pins (t3w2-s1-tokens-stage1, charter D33; the one licensed
// D43 amendment added the three closing-wave events):
//
//   • the needsYou rising-edge helper fires on prev<next ONLY — never on
//     initial (unknown prev), equal polls, or decreases,
//   • the registry is exactly the thirteen ratified events — the ten of D33
//     with its rename (refreshDone present, refreshSettle gone) plus the three
//     D43 events (archiveCommit, optionPick, jumpToLatest),
//   • needsYou = notification Warning (the single ratified deviation),
//   • the restraint law is structural: no event ever emits a Heavy impact, and
//     the impact palette stays {Light, Medium} — the D43 amendment added names,
//     not new feedback,
//   • 'settle' stays reserved: turnSettle is the only event carrying it,
//   • haptic() is fire-and-forget: a rejecting engine never throws.
import * as Haptics from 'expo-haptics'

import { HAPTIC_EVENTS, haptic, needsYouRisingEdge, type HapticEvent } from '../src/ui/haptics'

jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(() => Promise.resolve()),
  notificationAsync: jest.fn(() => Promise.resolve()),
  selectionAsync: jest.fn(() => Promise.resolve()),
  ImpactFeedbackStyle: { Light: 'light', Medium: 'medium', Heavy: 'heavy', Soft: 'soft', Rigid: 'rigid' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning', Error: 'error' },
}))

const impactAsync = Haptics.impactAsync as jest.Mock
const notificationAsync = Haptics.notificationAsync as jest.Mock
const selectionAsync = Haptics.selectionAsync as jest.Mock

beforeEach(() => {
  jest.clearAllMocks()
  impactAsync.mockImplementation(() => Promise.resolve())
  notificationAsync.mockImplementation(() => Promise.resolve())
  selectionAsync.mockImplementation(() => Promise.resolve())
})

describe('needsYouRisingEdge (the App.tsx blocked-badge edge)', () => {
  it('fires on a strict increase from a known count', () => {
    expect(needsYouRisingEdge(0, 1)).toBe(true)
    expect(needsYouRisingEdge(2, 5)).toBe(true)
  })

  it('is silent on initial load — an unknown prev is never an edge', () => {
    expect(needsYouRisingEdge(undefined, 0)).toBe(false)
    expect(needsYouRisingEdge(undefined, 7)).toBe(false)
  })

  it('is silent on equal polls and decreases', () => {
    expect(needsYouRisingEdge(3, 3)).toBe(false)
    expect(needsYouRisingEdge(3, 1)).toBe(false)
    expect(needsYouRisingEdge(1, 0)).toBe(false)
  })
})

describe('the thirteen-event registry (charter D33 + the one D43 amendment)', () => {
  it('is exactly the ratified vocabulary', () => {
    expect([...HAPTIC_EVENTS].sort()).toEqual(
      [
        'send',
        'turnSettle',
        'needsYou',
        'approve',
        'deny',
        'disclosureToggle',
        'refreshDone',
        'claim',
        'copy',
        'refused',
        // The three D43 events — the one licensed amendment.
        'archiveCommit',
        'optionPick',
        'jumpToLatest',
      ].sort(),
    )
  })

  it('carries the D33 rename: refreshDone in, refreshSettle out', () => {
    expect(HAPTIC_EVENTS).toContain('refreshDone')
    expect(HAPTIC_EVENTS).not.toContain('refreshSettle')
  })

  it("keeps 'settle' reserved for D77 turn settlement", () => {
    expect(HAPTIC_EVENTS.filter((e) => e.toLowerCase().includes('settle'))).toEqual(['turnSettle'])
  })

  it('needsYou is notification Warning — the single ratified deviation', () => {
    haptic('needsYou')
    expect(notificationAsync).toHaveBeenCalledTimes(1)
    expect(notificationAsync).toHaveBeenCalledWith('warning')
    expect(impactAsync).not.toHaveBeenCalled()
    expect(selectionAsync).not.toHaveBeenCalled()
  })

  it('restraint law: no event ever emits a Heavy impact', () => {
    for (const event of HAPTIC_EVENTS) haptic(event)
    for (const call of impactAsync.mock.calls) {
      expect(call[0]).not.toBe('heavy')
    }
  })

  it('the impact palette is exactly {light, medium} — D43 added names, not feedback', () => {
    for (const event of HAPTIC_EVENTS) haptic(event)
    const styles = new Set(impactAsync.mock.calls.map((call) => call[0]))
    expect([...styles].sort()).toEqual(['light', 'medium'])
  })

  it('the D43 three land in the right feedback class', () => {
    // archiveCommit is a commitment: Medium impact, like every other commitment
    // — a dismissal is something you COMMIT to, not a tick and not an outcome.
    haptic('archiveCommit')
    expect(impactAsync).toHaveBeenCalledTimes(1)
    expect(impactAsync).toHaveBeenCalledWith('medium')
    expect(notificationAsync).not.toHaveBeenCalled()
    expect(selectionAsync).not.toHaveBeenCalled()

    // optionPick and jumpToLatest are selection ticks and nothing else — a
    // notification here would report an outcome that never happened.
    jest.clearAllMocks()
    haptic('optionPick')
    haptic('jumpToLatest')
    expect(selectionAsync).toHaveBeenCalledTimes(2)
    expect(impactAsync).not.toHaveBeenCalled()
    expect(notificationAsync).not.toHaveBeenCalled()
  })
})

describe('fire-and-forget', () => {
  it('a rejecting haptics engine never throws or leaks a rejection', async () => {
    impactAsync.mockImplementation(() => Promise.reject(new Error('no engine')))
    notificationAsync.mockImplementation(() => Promise.reject(new Error('no engine')))
    selectionAsync.mockImplementation(() => Promise.reject(new Error('no engine')))
    for (const event of HAPTIC_EVENTS) {
      expect(() => haptic(event as HapticEvent)).not.toThrow()
    }
    // Flush the microtask queue — a swallowed rejection must stay swallowed.
    await new Promise((resolve) => setTimeout(resolve, 0))
  })
})
