// Haptic vocabulary — the thirteen-event semantic registry (t3code wave, lane 5;
// charter D33, amended ONCE by D43). Call sites say haptic('turnSettle'), NEVER
// raw impact styles.
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
//
// THE ONE LICENSED AMENDMENT (charter D43, closing wave round 2): t3w2-s7
// shipped swipe-to-archive and the picker sheet with no honest event for either
// moment, and the motion slice left the jump pill on `disclosureToggle`. Three
// events join — archiveCommit, optionPick, jumpToLatest — and D33 otherwise
// stands verbatim. Note what the amendment deliberately does NOT do: it adds no
// new FEEDBACK, only new NAMES for feedback the palette already had. The impact
// palette stays exactly {Light, Medium} — no Heavy (law), and no Soft or Rigid
// either, because a fourth and fifth weight nobody can tell apart in a pocket
// is vocabulary inflation dressed as nuance. 'settle' remains reserved.
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
  /** The archive swipe committed — a DISMISSAL commitment (D43).
   *
   * Medium, like every other commitment, and that is the point: the four
   * existing Medium events (send/approve/deny/claim) are all things you say TO
   * the fleet, so borrowing one of them for "make this row go away" would
   * mislabel the moment in the code even though the buzz would be identical.
   * The weight is right; only the name was missing. It fires at the moment the
   * gesture is DECIDED (release past the threshold), never when the request
   * lands — the phone reports your commitment, not the server's answer, which
   * is what `refused` is for. */
  archiveCommit: () => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium),
  /** A picker chip chosen — mode/model/effort — a selection tick (D43).
   * s7 honestly used `disclosureToggle` for the sheet OPENING (a sheet IS a
   * disclosure) and then had nothing left for the choice inside it. */
  optionPick: () => Haptics.selectionAsync(),
  /** The jump-to-latest pill pressed — a selection tick (D43).
   * Re-engaging follow mode is a position choice, not a disclosure: the same
   * tick the pill already emitted, finally under its own name. */
  jumpToLatest: () => Haptics.selectionAsync(),
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
