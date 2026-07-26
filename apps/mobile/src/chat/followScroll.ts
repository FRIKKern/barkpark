// The PURE follow-mode decision module — the mobile expression of the law
// lane 2 states once for all three surfaces: FOLLOW IS A STATE THE USER OWNS.
// The Go TUI already holds it (keys.go's scroll = -1 follow sentinel: a
// scroll-up pins, returning to the bottom re-enters, send re-follows) and
// Studio gets it free from column-reverse. Mobile did not: two unconditional
// scrollToEnd yanks — a 50 ms timer and onContentSizeChange — dragged the
// viewport back down on every token frame, so reading history mid-turn was
// physically impossible. There was no disengage path at all.
//
// The split with @legendapp/list is deliberate and is NOT a second copy of the
// same decision:
//
//   • the LIST owns the PHYSICS. maintainScrollAtEnd re-pins on data change,
//     item layout, footer layout and container layout, so a row that measures
//     LATE (MermaidIsland reports its height asynchronously, by postMessage)
//     cannot strand the tail off-screen. Its own maintainScrollAtEndThreshold
//     means it re-pins only while the viewport is already near the end — the
//     list never fights a reader.
//   • THIS module owns the AFFORDANCE: whether the user is following, and
//     whether the scroll-to-bottom pill has anything to offer. The list has no
//     opinion to render and no seam a test can drive; a pure reducer has both.
//
// Both read the SAME threshold constant, so the pill can never disagree with
// the physics about where "the end" is.
//
// Purity is the test seam, exactly as in reducer.ts and herd.ts: no refs, no
// clock, no native host — every rule below is a frozen-input function.

/** The engage/disengage threshold, as a fraction of the viewport — the twin of
 * LegendList's `maintainScrollAtEndThreshold` (whose default is the same 0.1)
 * and the same symmetric shape as the TUI's re-enter-at-bottom law. ONE
 * constant: the pill and the list must agree on where "the end" is, or the
 * pill offers a jump the list has already made. */
export const FOLLOW_THRESHOLD = 0.1

/** Follow truth. `mark` is the content mark captured at the MOMENT follow was
 * lost; while following it is '' and means nothing.
 *
 * Growth is therefore never an event and never a counter — the pill compares
 * the mark it left against the mark now. That is not a stylistic preference:
 * an accumulator has to be fed from somewhere, and the only place to feed it
 * from is an effect that fires on every token frame. Deriving instead makes
 * the pill's condition a comparison React already has the inputs for. */
export interface FollowState {
  following: boolean
  mark: string
}

/** Boot state: following. A session opens pinned to the newest turn (the list
 * boots with initialScrollAtEnd for the same reason). */
export const initialFollowState: FollowState = { following: true, mark: '' }

/** "How much content is below", cheaply: the row count and the live tail's
 * length. Either moving means something new arrived — and both are already in
 * hand at render time, so nothing has to be observed to know it. */
export function contentMark(rowCount: number, tailLength: number): string {
  return `${rowCount}:${tailLength}`
}

/** What can change follow truth.
 *
 *   scrolled — the only STRUCTURAL disengage. Follow is left because the user
 *              moved the viewport, never because a timer fired. Carries the
 *              content mark to freeze at.
 *   sent     — the user submitted a message: send always re-follows, because
 *              they are now waiting on an answer they asked for.
 *   jumped   — the scroll-to-bottom pill was tapped.
 */
export type FollowEvent =
  | { type: 'scrolled'; distanceFromEnd: number; viewportHeight: number; mark: string }
  | { type: 'sent' }
  | { type: 'jumped' }

/** Is the viewport within the threshold band of the end?
 *
 * Pre-layout (a zero/absent viewport height, which is what the first frames
 * report) counts as AT the end: a session that has not measured itself yet is
 * booting pinned, and treating it as disengaged would raise the pill over an
 * empty transcript. */
export function nearEnd(
  distanceFromEnd: number,
  viewportHeight: number,
  threshold: number = FOLLOW_THRESHOLD,
): boolean {
  if (viewportHeight <= 0) return true
  return distanceFromEnd <= viewportHeight * threshold
}

/** The whole state machine. Returns the SAME object when nothing changed —
 * identity stability is load-bearing here, because this state is a dependency
 * of the memoized renderItem: a new object on every scroll frame would re-mint
 * every row's props and quietly undo memo(TranscriptRow). */
export function reduceFollow(st: FollowState, ev: FollowEvent): FollowState {
  switch (ev.type) {
    case 'scrolled': {
      const at = nearEnd(ev.distanceFromEnd, ev.viewportHeight)
      if (at === st.following) return st
      // Crossing the band DOWNWARD is catching up — follow, and the mark stops
      // meaning anything. Crossing it upward freezes the mark: everything that
      // arrives from here on is what the pill is offering to show.
      return at ? initialFollowState : { following: false, mark: ev.mark }
    }
    case 'sent':
    case 'jumped':
      return st.following ? st : initialFollowState
  }
}

/** The pill's visibility, and the ONLY predicate the screen may ask.
 * Disengaged AND content has arrived since — a reader who scrolled up into a
 * quiet transcript is left alone. */
export function showJumpPill(st: FollowState, mark: string): boolean {
  return !st.following && mark !== st.mark
}

/** How far from the end a scroll event sits, derived from the ScrollView
 * geometry every RN list reports. Extracted so the screen's onScroll handler
 * carries no arithmetic of its own and the sign convention is pinned once:
 * distance is measured from the BOTTOM edge of the viewport to the bottom of
 * the content, and is clamped at 0 (iOS rubber-band overscroll reports a
 * negative remainder, which must read as "at the end", not as a jump). */
export function distanceFromEnd(geo: {
  contentHeight: number
  offsetY: number
  viewportHeight: number
}): number {
  return Math.max(0, geo.contentHeight - geo.offsetY - geo.viewportHeight)
}
