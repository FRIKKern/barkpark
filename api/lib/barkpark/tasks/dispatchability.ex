defmodule Barkpark.Tasks.Dispatchability do
  @moduledoc """
  Is a ready row a SLICE a builder can be sent at, or an UMBRELLA whose
  remaining work is its children's?

  ## The burn this exists for (task-52f4f3aff99c64d5)

  `bp task ready` returned `task-fb4fb869490b4213` as PRIORITY 0. It is not
  work: it is an epic root carrying 359 children whose last criterion reads
  "SEAL — THE LEAD CLOSES THIS", and whose claim had lapsed so the lease
  sweeper put it back on the queue. On the ready card it rendered
  INDISTINGUISHABLY from a lapsed leaf defect — same fields, same priority,
  a headline its own met criterion 0 forbids anyone from quoting as current.
  A lead who reads a title and a priority at 4 a.m. claims it in good faith
  and dispatches a builder at work that does not exist.

  The cheap answer — a doc line telling leads to "check child_count first" —
  is refused by the filing on purpose: every lane already carries more
  doctrine than it can hold, and the failure mode IS a tired reader. The
  burden has to move off the reader and into the instrument's own output.

  ## The signal is STRUCTURE, never vocabulary

  Deliberately NOT a list of known umbrella ids (it would fire only on the
  rows someone already met) and NOT title or criterion wording. Measured on a
  live 1,000-row `bp task ready` page 2026-09-07: a bare case-insensitive
  `seal` over criterion text matches 23 rows, and MOST of them are ordinary
  buildable slices about the *seal predicate script*
  (`tooling/grip/seal.mjs`, `seal-predicate.mjs`, `scripts/seal-run.sh`) —
  the vocabulary reads a tool's name, not a row's shape. The clause "the LEAD
  closes this" is worse still: it is merge-gate boilerplate on ordinary
  slices.

  What DOES separate them is the parent edge, which no author phrases:

      classify(total_children, live_children)

    * `nil`         — zero children. A leaf. The card is byte-identical to
                      what it has always been (the negative arm).
    * `"delegated"` — at least one child is NOT terminal. The row's remaining
                      work is downstream, being done by someone else. Sending
                      a builder here duplicates a child.
    * `"undecided"` — children exist and every one is terminal. The rule
                      REFUSES to call this either way rather than silently
                      defaulting it to dispatchable: it is equally a
                      seal-ready epic whose lead should close it and a defect
                      row whose one follow-up shipped and whose own residual
                      criteria are real work. Distinguishing those needs the
                      row's criteria, and this rule does not read prose.

  Measured over that same live page (children rosters re-read per parent):
  21 of 1,000 rows carry children at all; 15 classify `delegated`, 6
  `undecided`, and 979 are untouched leaves — strictly less than the page, and
  20 of the 21 are rows other than the one that prompted this.

  ## What it costs, hand-labelled — read this before trusting it

  Of the 15 `delegated`, 11 are true (epic roots, GOAL rows, wave rows, the
  campaign root, and a human-DECISION row). FOUR are FALSE POSITIVES, all the
  same shape: an ordinary defect row that spun off ONE follow-up child while
  keeping real own-work — `task-18f209f185f5b3f1`,
  `bp-dataset-project-routing-gap`, `task-597ea451072da061`,
  `spd-b45-deleted-task-orphans-github-mirror`. Precision 11/15; on the page,
  4 in 1,000. The cost of a false positive is a skipped row, not a lost one:
  the marker never removes anything from the queue.

  FALSE NEGATIVES are the bigger hole and this rule CANNOT see them. A seal
  row whose children hang off a DIFFERENT root carries child_count 0 and
  renders as an ordinary leaf. Five confirmed on the same page:
  `task-08b05ad1e792a850` ("GOAL: drive the mobile epic to the seal", PRIORITY
  0 — the exact trap this module was filed for, and it walks straight past),
  `task-b55fafd148bb2578`, `survey-once-build-forever-epic`,
  `legendary-quality-takeover-final-review`, `ecd-bl-second-env-launch-proof`.
  Recall against the hand-labelled set is 11/16.

  Their signal is not the outbound parent edge but an INBOUND one: a criterion
  that requires ANOTHER task id to be CLOSED. Measured on the same page, a
  criterion naming a `task-<16 hex>` id alongside "closed" matches 8 of 988
  rows and about three are genuine — better than vocabulary, not yet
  shippable. That is a separate slice, filed, not smuggled in here.

  ## Why `live` and not just a positive count

  `child_count` alone (already on the wire) would flag all 21, including
  `chat-local-cloud-context-w3` — 3 children, all done, 1 of 3 own criteria
  met — which is plausibly its own residual work, not an umbrella. The live
  arm is what buys the discrimination, and it is the signal the filing itself
  named: "a positive child_count with open children".
  """

  @typedoc "The dispatch class, or `nil` for an ordinary leaf row."
  @type class :: nil | String.t()

  @terminal_statuses ~w(done cancelled)

  @doc """
  The `lifecycle_status` values that make a child DEAD for this rule.

  The complement — `open`, `blocked`, `in_progress`, `considering`,
  `researching`, and an ABSENT status — is live. Absent counts as live on
  purpose: a child with no status is a child nobody has resolved, and the
  conservative reading of an unresolved child is that the work is still out
  there. (Measured 2026-09-07 across the 460 children of the 21 parents on a
  live ready page: zero children carried a null status, so this arm is a
  guard, not a load-bearing case.)
  """
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc """
  Classify a row from its child edges alone. See the moduledoc.

  Defensive on nils so a missing count map entry reads as zero rather than
  raising inside a render.
  """
  @spec classify(integer() | nil, integer() | nil) :: class()
  def classify(total, live)

  def classify(nil, _live), do: nil
  def classify(total, _live) when not is_integer(total) or total <= 0, do: nil
  def classify(_total, live) when is_integer(live) and live > 0, do: "delegated"
  def classify(_total, _live), do: "undecided"
end
