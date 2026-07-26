// The PURE turn-scoped work log — lane 2's fold, and the exact sibling of the
// typed chat-* renderers: those own how one apparatus row LOOKS; this owns
// which rows form a GROUP and whether that group is open. Neither knows about
// the other, and neither imports the screen.
//
// THE FOLD CLOCK IS THE REDUCER'S, READ-ONLY. `gen` — the D77 settle-race
// fence's own generation — already increments on every system/init frame
// because the fence needs it. So the fold reuses it verbatim: a group folds
// when the clock has moved past the turn it was born in. reducer.ts gains no
// field, no event and no semantics, and no SECOND turn-boundary detector is
// invented anywhere — which is the precise mistake lane 2 warned about (two
// detectors drift, and the one that drifts is always the cosmetic one).
//
// Purity is the test seam (reducer.ts / herd.ts / followScroll.ts discipline):
// the fold is a function of (rows, gen, user overrides) with no clock, no
// refs, and no native host.

/** The apparatus roles — what the agent DID, as opposed to what it said.
 * Exactly the three block-bearing NON-card roles of the persisted eight:
 *
 *   • user / assistant delimit turns, so they can never fold into one;
 *   • approval / question / plan stay first-class no matter how old — a human
 *     has to answer them, and an answer hidden behind a disclosure is an
 *     answer that never comes.
 *
 * The set is declared here once and read by isWorkLogRole; the screen's role
 * taxonomy (roleKind) keeps its own job of deciding how a row PAINTS. */
export const WORK_LOG_ROLES: readonly string[] = ['tool', 'todo', 'thinking']

export function isWorkLogRole(role: string): boolean {
  return WORK_LOG_ROLES.includes(role)
}

/** The minimal row projection the fold reads. Deliberately NOT the screen's
 * `Row` union: keeping the shape structural is what lets this module stay
 * importable from anywhere and keeps the screen → chat edge one-directional,
 * the same posture chat.tsx holds against blocks.tsx. */
export interface WorkLogRow {
  key: string
  role: string
}

/** One run of consecutive apparatus rows — a turn's visible labour. */
export interface WorkLogGroup {
  /** The first member's row key. Stable while the run keeps its head, which is
   * what lets the fold state and the user's disclosure survive the run GROWING
   * mid-turn (rows are appended, never prepended). */
  key: string
  /** Member row keys, in transcript order. */
  members: string[]
  /** Member roles, positionally aligned with `members`. */
  roles: string[]
}

/** Split a transcript into its apparatus runs. Only CONSECUTIVE apparatus rows
 * group: an assistant turn between two tool rows genuinely separates two
 * stretches of work, and merging across it would claim a shape the transcript
 * does not have. */
export function workLogGroups(rows: readonly WorkLogRow[]): WorkLogGroup[] {
  const groups: WorkLogGroup[] = []
  let open: WorkLogGroup | undefined
  for (const row of rows) {
    if (!isWorkLogRole(row.role)) {
      open = undefined
      continue
    }
    if (open === undefined) {
      open = { key: row.key, members: [row.key], roles: [row.role] }
      groups.push(open)
      continue
    }
    open.members.push(row.key)
    open.roles.push(row.role)
  }
  return groups
}

/** The collapsed line — a count, and nothing it cannot back up. No elapsed
 * time (the wire carries none for a settled turn), no "thinking hard", no
 * summary of work the client never saw. */
export function workLogSummary(group: WorkLogGroup): string {
  const n = group.members.length
  return n === 1 ? '1 step' : `${n} steps`
}

/** The fold's whole state.
 *
 *   born      — group key → the D77 gen the group was FIRST observed at. This
 *               is the clock reading; everything else is derived.
 *   overrides — group key → the user's explicit disclosure. A hand always wins
 *               over the clock, and permanently: someone who opened an old log
 *               to read it must not have it slammed shut by the next turn. */
export interface WorkLogFold {
  born: Readonly<Record<string, number>>
  overrides: Readonly<Record<string, boolean>>
}

export const initialWorkLogFold: WorkLogFold = { born: {}, overrides: {} }

/** Stamp the clock onto any group seen for the first time. Returns the SAME
 * object when there is nothing new to stamp — identity stability keeps this
 * out of the memoized renderItem's dependency churn. */
export function observeGroups(
  fold: WorkLogFold,
  groups: readonly WorkLogGroup[],
  gen: number,
): WorkLogFold {
  let born: Record<string, number> | undefined
  for (const group of groups) {
    if (fold.born[group.key] !== undefined) continue
    born ??= { ...fold.born }
    born[group.key] = gen
  }
  return born === undefined ? fold : { born, overrides: fold.overrides }
}

/** THE FOLD, on the D77 clock.
 *
 * A group born at the LIVE generation is the turn in flight — open, so the
 * work scrolls past as it happens. The instant `gen` advances (a new
 * system/init frame — the fence's own increment, not a heuristic) every group
 * born earlier is behind a finished turn, and folds. A group not yet observed
 * reads as live: it can only have appeared under the current clock. */
export function workLogExpanded(fold: WorkLogFold, key: string, gen: number): boolean {
  const override = fold.overrides[key]
  if (override !== undefined) return override
  const born = fold.born[key]
  return born === undefined || born >= gen
}

/** The disclosure tap. Records the OPPOSITE of what is currently shown, so the
 * override is always meaningful (writing `true` onto an already-open group
 * would produce a control that does nothing on its first press). */
export function toggleWorkLog(fold: WorkLogFold, key: string, gen: number): WorkLogFold {
  return {
    born: fold.born,
    overrides: { ...fold.overrides, [key]: !workLogExpanded(fold, key, gen) },
  }
}

/** Fold a row list into its PRESENTATION order: every apparatus run becomes a
 * disclosure header, followed by its member rows only while the group is open.
 *
 * Generic over the row type, with the key accessor and the header constructor
 * both supplied by the caller — so the screen's `Row` union stays in the
 * screen and this module imports nothing at all. Rows outside every group pass
 * through untouched and in order; a folded group leaves exactly its header
 * behind, so the transcript never silently loses a row it does not replace. */
export function foldWorkLog<R>(
  rows: readonly R[],
  groups: readonly WorkLogGroup[],
  keyOf: (row: R) => string,
  isOpen: (groupKey: string) => boolean,
  header: (group: WorkLogGroup, open: boolean) => R,
): R[] {
  const groupOf = new Map<string, WorkLogGroup>()
  for (const group of groups) for (const member of group.members) groupOf.set(member, group)

  const out: R[] = []
  for (const row of rows) {
    const key = keyOf(row)
    const group = groupOf.get(key)
    if (group === undefined) {
      out.push(row)
      continue
    }
    const open = isOpen(group.key)
    if (key === group.key) out.push(header(group, open))
    if (open) out.push(row)
  }
  return out
}
