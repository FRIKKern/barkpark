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
  shippable. That was filed as `task-e8d0fe00383f8499`, and
  `classify_upstream/3` below is what came back — read its own section
  before trusting it, because it is the WEAKEST of the three classes on
  this card.

  ## Why `live` and not just a positive count

  `child_count` alone (already on the wire) would flag all 21, including
  `chat-local-cloud-context-w3` — 3 children, all done, 1 of 3 own criteria
  met — which is plausibly its own residual work, not an umbrella. The live
  arm is what buys the discrimination, and it is the signal the filing itself
  named: "a positive child_count with open children".
  ## The second population: `classify_upstream/3` (task-e8d0fe00383f8499)

  `classify/2` above reads the OUTBOUND edge and is therefore blind to a seal
  row whose children hang off a different root: `child_count` is 0 and the
  card is an ordinary leaf. `classify_upstream/3` reads the INBOUND edge
  instead — the row's own `parent_id` — and asks one question:

      does an UNMET criterion of this row name its own STILL-LIVE parent?

  A row that cannot be marked done until the tree ABOVE it moves is not a
  slice a builder finishes, whatever its child count says. No vocabulary is
  involved: the matched token is the row's own `parent_id`, whatever string
  that happens to be (`task-<hex>` and slug parents alike), and liveness is
  the same `terminal_statuses/0` predicate `classify/2` uses. Neither refuted
  vocabulary signal is reachable from here — not the "the LEAD closes this"
  clause (merge-gate boilerplate on ~32% of ordinary rows) and not a bare
  `seal` token (23 of 1,000 hits, most of them rows ABOUT
  `tooling/grip/seal.mjs`).

  ### What it costs, hand-labelled — this bucket is the least accurate one

  Measured on the same live 1,000-row `bp task ready` page 2026-09-07 (982 of
  the 1,000 rows resolve to a published doc carrying criteria; 815 carry a
  parent; 649 carry a LIVE parent): NINE rows match. One of them,
  `github-bridge-mirror-exposure-decision`, already carries `delegated` from
  the outbound edge and keeps it — `classify/2` wins every tie — so EIGHT
  leaves gain the new marker, and 992 of 1,000 cards are byte-identical.

  Of the nine, TWO are seal/GOAL rows on the strict reading:
  `task-08b05ad1e792a850` ("GOAL: drive the mobile epic to the seal", PRIORITY
  0 — the exact row `classify/2` walks past) and `pe-w7-epic-seal`. THREE more
  are not builder slices either on the broad reading: `pe-bl-cold-agent-run`
  and `sup-w4-pixel-evidence` (both fold their output into a live epic and say
  the LEAD closes them) and `github-bridge-mirror-exposure-decision` (a human
  DECISION row). FOUR are plain FALSE POSITIVES, all one shape — an ordinary
  buildable row that happens to cite its own parent in prose:
  `task-cth-w1-dogfood`, `spd-b42-provenance-cites-superseded-run`,
  `task-b42889695dc3acb3`, `task-5cfd00cb333e0bb3`.

  Precision 2/9 strict, 5/9 broad. That is WORSE than `delegated`'s 11/15 and
  the aggregate does NOT hold inside the buckets, which is why this class is
  worded as a REFUSAL rather than a verdict: `upstream` means "an unmet
  criterion here names a live parent — LOOK before dispatching", never "do not
  dispatch". The cost of being wrong is a reader opening one row; the cost of
  the miss it exists for was a builder sent at a P0 GOAL row with no work in
  it.

  ### Recall: this covers ONE of the five known misses, not five

  Stated plainly so nobody reads half a fix as the whole one. Of the five
  childless seals `classify/2` misses, `classify_upstream/3` catches exactly
  ONE — `task-08b05ad1e792a850`. The other four are invisible to it and stay
  invisible: `task-b55fafd148bb2578` and `survey-once-build-forever-epic`
  carry NO parent at all, and `legendary-quality-takeover-final-review` and
  `ecd-bl-second-env-launch-proof` carry a live parent but never name it in
  any criterion. Combined recall of the two rules against the hand-labelled
  16-row set is 12/16, up from 11/16. The remaining four have no measured
  structural signal — the inbound-edge idea does not reach them, and saying so
  is cheaper than a marker that guesses.

  ### What it DECLINES to judge, named rather than defaulted

  Three populations get NO key, and none of them is thereby called
  dispatchable: (a) a row with no `parent_id` — 185 of the 1,000 on the
  measured page; (b) a row whose parent is terminal — 166 more, where the tree
  above it has already stopped; (c) EVERY row, when `live_parents` is `nil`,
  i.e. a caller that did not pay for the parent-liveness query. `nil` means
  UNMEASURED and emits nothing, on the same law as `live_child_counts`.
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

  @doc """
  The INBOUND-edge class for the population `classify/2` cannot see:
  `"upstream"` when an UNMET criterion of this row names its own STILL-LIVE
  parent, else `nil`.

  See the moduledoc section "The second population" — precision 2/9 strict,
  5/9 broad on a hand-labelled 1,000-row page, recall 1 of the 5 known
  childless seals. It is a LOOK-HERE, not a refusal to dispatch, and
  `classify/2` outranks it wherever both speak.

  `live_parents` is a set-like map keyed by the parent doc_ids measured LIVE.
  `nil` means the caller never measured, and answers `nil` rather than
  guessing — an empty map would read as "no parent is live", a measurement
  nobody made.
  """
  @spec classify_upstream(String.t() | nil, %{optional(String.t()) => any()} | nil, list() | nil) ::
          class()
  def classify_upstream(parent_id, live_parents, criteria)

  def classify_upstream(nil, _live_parents, _criteria), do: nil
  def classify_upstream(_parent_id, nil, _criteria), do: nil

  def classify_upstream(parent_id, live_parents, criteria)
      when is_binary(parent_id) and is_map(live_parents) and is_list(criteria) do
    if Map.has_key?(live_parents, parent_id) and names_parent_in_unmet?(criteria, parent_id),
      do: "upstream"
  end

  def classify_upstream(_parent_id, _live_parents, _criteria), do: nil

  # An unmet criterion is one whose `met` is not exactly `true` — absent,
  # false, or a non-boolean all read as unmet, which is the conservative
  # direction: a criterion nobody stamped is work nobody did.
  defp names_parent_in_unmet?(criteria, parent_id) do
    Enum.any?(criteria, fn
      %{} = c ->
        Map.get(c, "met") != true and
          is_binary(Map.get(c, "criterion")) and
          String.contains?(Map.get(c, "criterion"), parent_id)

      _ ->
        false
    end)
  end
end
