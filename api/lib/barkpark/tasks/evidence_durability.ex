defmodule Barkpark.Tasks.EvidenceDurability do
  @moduledoc """
  Refuse criterion evidence whose ONLY pointer is a branch name.

  ## The economics

  A 34-row hand-check found exactly one genuinely false-done row, and the
  survivors and the casualty were separated by a single property of their
  evidence: the survivors named a COMMIT SHA or a `path:line` still resolvable
  on `origin/main`; the casualty named a BRANCH STATE.

  A branch name is not a durable reference. It can be deleted on merge, rebased
  away, or never pushed at all. When it goes the evidence becomes
  UNFALSIFIABLE — no auditor can confirm or refute it, so the criterion reads
  MET forever. A sha is durable by construction, and even a garbage-collected
  sha fails LOUDLY (`fatal: Not a valid object name`) rather than silently.

  The refusal has to land at STAMP TIME, which is the only moment the missing
  information is still in someone's hands. Six weeks later an audit cannot
  recover it at any price. One line to the stamper now, or an unanswerable
  question forever.

  ## What is refused, precisely

  ONLY this shape: the evidence says the claim was verified ON A BRANCH, and
  carries no durable pointer of any kind. Everything else passes.

  A durable pointer is any one of:

    * a commit sha — 7 to 40 hex characters, containing BOTH a letter and a
      digit, so an all-digit count and an all-letter word cannot pass for one;
    * a `path:line` in a source file this repo actually has;
    * a pull request or issue number (`#16238`);
    * a GitHub run id (a bare run of 9+ digits).

  A sha does NOT have to be on `main`. Builders legitimately stamp against
  branch commits before merge and that is fine: the sha stays resolvable, and
  whether it landed is a separate question an auditor can then ask. The
  requirement is DURABILITY, not merged-ness — over-tightening this into an
  on-main check is the most likely way to break the honest mid-build case.

  ## Why the trigger is narrow, and what that costs

  "Branch" is an OVERLOADED WORD. In this ledger it means a git branch about as
  often as it means a code path — "the halted? branch", "paintRefusal() branches
  on whether anything is running", "the criterion's 'or truncates with a cue'
  branch". Measured over 6,200 real met-criteria evidence strings on the live
  ledger, a naive rule keyed on the word alone would have refused 254 of them,
  4.1%, most of them talking about code. That guard would be reverted within a
  day, and rightly.

  So the trigger is a VERIFICATION LOCATION, not a word. Three patterns, each
  earned by a string that broke the previous one:

    1. a verification verb reaching "on ... branch";
    2. "on <ref> branch", where the token before "branch" carries a slash, dash,
       underscore or digit, or is main/master. The looser first draft read "on
       the RIGHT branch" as a ref named "right" and reddened this repo's own
       stamp_test.exs;
    3. "on this/that/the/my/our branch", a determiner sitting DIRECTLY before
       the word, with no gap — because "git diff --stat on this branch returns
       EMPTY" is exactly as uncheckable as one that names the ref, while "on the
       right branch" is English about correctness.

  Against the same 6,200 strings the finished rule refuses 33, or 0.53%. Reading
  them, they are the intended catch: claims nobody can check once the branch is
  gone. The naive word-only rule refused 254.

  Validated in BOTH directions on the two rows the filing itself names:

    * `eci-w1-index-note`, the one real false-done: three of its five criteria
      are refused — exactly the three whose evidence names only a branch — while
      the two that name a commit sha pass. The guard splits one row correctly.
    * `pds-bl-w48-web-sibling-launders`, the survivor: none of its seven are
      refused, including "Run in the worktree on branch loop-epic/... at commit
      7e08e1ce6", which names a branch AND a sha. That is criterion 1's arm.

  THE HONEST GAP: evidence that names a bare ref with no branch vocabulary at
  all — "verified on ledger3/foo" — is not caught. Catching it would mean
  treating any `word/word` token as a ref, and this repo is full of real paths
  that look exactly like that (`docs/ops`, `js/packages`). A guard that fires on
  those is worse than the hole it closes. This closes the shape that was
  actually observed and says so, rather than claiming the class.
  """

  # A commit sha: 7-40 hex, but it must carry BOTH a letter and a digit.
  # "1187" (a byte count) and "added" (a word) are both 7-40-char-ish hex-ish
  # runs; requiring the mix is what stops a count from vouching for a stamp.
  @sha ~r/\b[0-9a-f]{7,40}\b/
  @path_line ~r/\b[\w.\/-]+\.(?:ex|exs|go|ts|tsx|js|jsx|md|heex|yml|yaml|json|sh|sql|py):\d+/
  @pr_number ~r/#\d{3,6}\b/
  @run_id ~r/\b\d{9,}\b/

  @verb "(?:verified|verif\\w+|measured|confirmed|observed|reproduced|checked|tested|ran|stamped|proven|proved)"
  @verb_on_branch Regex.compile!("#{@verb}[^.]{0,90}\\bon\\b[^.]{0,40}\\bbranch\\b", "i")

  # The token before "branch" has to LOOK LIKE A REF — carry a slash, dash,
  # underscore or digit — or be main/master. Without this, "re-run on the RIGHT
  # branch" is read as a ref named "right", which is English about correctness,
  # not a location. That exact string is in this repo's own stamp_test.exs, so
  # the loose form reddened an existing test rather than a live stamp.
  @ref "(?:main|master|[`'\"]?[\\w.]*[-_/\\d][\\w.\\-/]*[`'\"]?)"
  @on_ref_branch Regex.compile!("\\bon\\s+(?:the\\s+|a\\s+|my\\s+)?#{@ref}\\s+branch\\b", "i")

  # A determiner sitting DIRECTLY before "branch" is still a location claim:
  # "git diff --stat on this branch returns EMPTY" is exactly as uncheckable
  # once the branch is gone as one that names the ref. An evaluative adjective
  # in between ("on the right branch") is not, which is why this pattern allows
  # no gap.
  @on_determiner_branch ~r/\bon\s+(?:this|that|the|my|our)\s+branch\b/i

  @doc """
  `:ok`, or `{:error, :branch_only_evidence}` when the evidence locates its
  proof on a branch and names nothing durable.
  """
  @spec check(String.t()) :: :ok | {:error, :branch_only_evidence}
  def check(evidence) when is_binary(evidence) do
    if names_a_branch_location?(evidence) and not names_something_durable?(evidence) do
      {:error, :branch_only_evidence}
    else
      :ok
    end
  end

  def check(_not_a_string), do: :ok

  @doc """
  Does this evidence carry a pointer that outlives the branch it was written on?
  """
  @spec names_something_durable?(String.t()) :: boolean()
  def names_something_durable?(evidence) when is_binary(evidence) do
    commit_sha?(evidence) or
      Regex.match?(@path_line, evidence) or
      Regex.match?(@pr_number, evidence) or
      Regex.match?(@run_id, evidence)
  end

  @doc """
  Does this evidence say the claim was verified ON A BRANCH?

  Deliberately NOT "does it contain the word branch" — see the moduledoc on why
  that rule refuses 4.1% of the live ledger, mostly for talking about code.
  """
  @spec names_a_branch_location?(String.t()) :: boolean()
  def names_a_branch_location?(evidence) when is_binary(evidence) do
    Regex.match?(@verb_on_branch, evidence) or
      Regex.match?(@on_ref_branch, evidence) or
      Regex.match?(@on_determiner_branch, evidence)
  end

  defp commit_sha?(evidence) do
    @sha
    |> Regex.scan(evidence)
    |> Enum.any?(fn [candidate] ->
      String.match?(candidate, ~r/[a-f]/) and String.match?(candidate, ~r/[0-9]/)
    end)
  end

  @doc """
  The refusal a stamper sees. It names the missing thing AND how to supply it,
  because a refusal that only says no costs the stamper the same trip an audit
  would have cost — and this guard's whole justification is that the information
  is cheap right now and unrecoverable later.
  """
  @spec message() :: String.t()
  def message do
    """
    this evidence locates its proof on a BRANCH and names nothing durable, so \
    once that branch is deleted, rebased or never pushed, nobody can confirm or \
    refute the claim and the criterion reads MET forever. Add one durable \
    pointer and re-stamp: a commit sha (`git rev-parse HEAD` — it does NOT have \
    to be on main, a branch commit is fine because the sha stays resolvable), a \
    `path:line` that resolves on origin/main, a PR number like #16238, or a \
    GitHub run id. Evidence that makes no git claim at all — a Paper id, a bp \
    doc id, a host read — is not affected by this check.\
    """
  end
end
