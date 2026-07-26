// Haptic vocabulary — the ten-event semantic registry (t3code wave, lane 5;
// charter D33). Call sites say haptic('turnSettle'), NEVER raw impact styles.
//
// RESTRAINT LAW (t3code's measured restraint, verbatim):
//   • no Heavy impact — anywhere, ever;
//   • no haptic in a loop;
//   • no haptic on render;
//   • every call fire-and-forget;
//   • raw `Haptics.*` outside src/ui/haptics.ts is a review reject.
// Selection ticks dominate; Medium impact only for commitment; notification
// only for terminal outcomes.
//
// needsYou = notification Warning is the single ratified deviation from
// t3code's never-Warning restraint (ratified call #6): a blocked session
// waiting on a human IS the app's reason to exist.
//
// D33 rename: t3code's refresh-"settle" event is `refreshDone` here —
// 'settle' is reserved for D77 turn settlement, and pull-to-refresh
// completion is not one (turnSettle IS D77-legit and keeps its name).
import * as Haptics from 'expo-haptics'

const registry = {
  /** Message sent — a commitment. */
  send: () => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium),
  /** Turn settled (D77 settlement) — a terminal outcome. */
  turnSettle: () => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success),
  /** A session newly needs a human — the ratified Warning deviation. */
  needsYou: () => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning),
  /** Permission ask approved — a commitment. */
  approve: () => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium),
  /** Permission ask denied — a commitment. */
  deny: () => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium),
  /** Disclosure row opened/closed — a selection tick. */
  disclosureToggle: () => Haptics.selectionAsync(),
  /** Pull-to-refresh completed (D33: NOT 'settle'). */
  refreshDone: () => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light),
  /** Task claimed — a commitment. */
  claim: () => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium),
  /** Copied to clipboard — a selection tick. */
  copy: () => Haptics.selectionAsync(),
  /** Request refused (auth/permission terminal failure). */
  refused: () => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error),
} as const

export type HapticEvent = keyof typeof registry

/** Every haptic event the app may emit — exported for the jest vocabulary pin. */
export const HAPTIC_EVENTS = Object.keys(registry) as HapticEvent[]

/** Fire-and-forget: haptics are garnish — a missing engine (simulator, web,
 * user setting) must never surface as an error or an await. */
export function haptic(event: HapticEvent): void {
  registry[event]().catch(() => undefined)
}

/** The needsYou rising edge over a polled count (App.tsx's blocked badge):
 * fire only when a KNOWN previous count strictly increases. Initial load
 * (prev undefined), equal polls and decreases are silent — reopening the
 * app onto an already-blocked board must not buzz. Pure; jest-pinned. */
export function needsYouRisingEdge(prev: number | undefined, next: number): boolean {
  return prev !== undefined && next > prev
}
