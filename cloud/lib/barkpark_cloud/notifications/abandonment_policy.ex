defmodule BarkparkCloud.Notifications.AbandonmentPolicy do
  @moduledoc """
  dr-w13-bl-abandonment-splits-off-the-flood — WHICH failed attempts are an
  ABANDONMENT, and how many refusals the chain took before it was given up on.
  One predicate, read by the single `:deployment_failed` funnel, so the fleet has
  exactly one answer to "was this publish given up on, or did it merely fail".

  ## The fault this closes (charter D193)

  The premise "an abandoned publish notifies nobody" is REFUTED: all seven
  abandonments on the live control plane carry a `notification_deliveries` row,
  event `deployment_failed`, status `sent`. `Sites.Deploy.fail/3` writes
  `status: "failed"` through `Registry.transition_deployment_fenced/4`, whose
  edge guard suppresses only `failed -> failed`, and an abandonment's prior
  status is `queued`/`building` — so the edge always fires on a won CAS.

  The defect is that **the most severe outcome in the fleet is indistinguishable
  from the least severe**: one event name, one renderer arm each side, one
  settings toggle, shared with ~870 routine failures a day. `DeployLedger`
  already classifies `ABANDONED_AT_CAPACITY` / `ABANDONED_BOX_STUCK` /
  `ABANDONED_UNCLASSIFIED` with distinct labels — the taxonomy is built; only the
  notification arm was undifferentiated. This module is the split and nothing
  else: it adds no producer, no dispatch and no reaper.

  ## The predicate keys on the CLASS, never on `deferral_depth` (charter D195)

  `DeployLedger.classify/1` is the one owner of the taxonomy, and it reads the
  abandonment out of the producer's own anchored terminal clause. The tempting
  alternative — `deferral_depth >= 12` — is ruled OUT by D195: the column is 22
  rows old with a max observed value of 4 on the deferred cohort, so a depth
  predicate returns ZERO forever on everything written before it landed. A
  reader that keys on the class inherits every fix the classifier gets, and a
  fourth `ABANDONED_*` class added upstream joins this cohort by naming
  convention rather than by someone remembering a second list.

  ## Which way the doubt falls

  A row this module cannot read — no `failure_reason`, a status that is not
  `failed` — is NOT an abandonment. That is the opposite direction from
  `DeploymentFailedPolicy`'s unkeyable-is-loud rule, and deliberately so: there
  the doubt decides whether a person is told AT ALL, here it decides only WHICH
  of two alerts they get. An unreadable row still reaches them as
  `:deployment_failed`, the alert it already got before this split existed. No
  silence is ever earned here.

  ## The count is a COLUMN, and the copy degrades rather than invents

  `Sites.Deploy`'s abandonment branch stamps `deferral_depth`/`deferral_bound`/
  `deferral_cause` in the SAME fenced write that sets `status: "failed"` (W28
  S6), so the struct the dispatch holds already carries the refusal count that
  the terminal sentence interpolates. Detection does not depend on it; only the
  "after N refusals" clause does, and a row whose column is NULL — every
  abandonment written before W28 S6 — renders "after repeated refusals" instead
  of a fabricated number.
  """
  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Registry.Deployment

  # The naming convention `DeployLedger.abandoned_class/1` writes, asked as a
  # question. `DeployLedger` derives its own `@abandoned_classes` from exactly
  # this prefix over `@classes` and exposes no public predicate; matching the
  # prefix is therefore the SAME derivation and not a second hand-list, which is
  # the failure mode that module's own comment names (a fourth `ABANDONED_*`
  # class would land outside a list and the cohort would silently shrink).
  @abandoned_prefix "ABANDONED_"

  @doc """
  Whether this failed attempt is a chain the fleet GAVE UP ON, and therefore
  earns `:deployment_abandoned` instead of `:deployment_failed`.

  Accepts a `Deployment` struct (the two synchronous producers hold one) or a
  plain map (the reaper holds only what its `select:` named — no
  `failure_reason`, so it can never be an abandonment, which is correct: the
  reaper's rows are stale-lease sweeps, not exhausted refusal chains).
  """
  @spec abandonment?(Deployment.t() | map() | nil) :: boolean()
  def abandonment?(%Deployment{} = deployment), do: abandoned_class?(deployment)

  def abandonment?(%{} = attempt), do: abandoned_class?(attempt)

  def abandonment?(_attempt), do: false

  @doc """
  How many refusals this chain took before it was abandoned — `nil` when the row
  does not carry the count, never a guess.
  """
  @spec refusals(Deployment.t() | map() | nil) :: pos_integer() | nil
  def refusals(%Deployment{deferral_depth: depth}) when is_integer(depth) and depth > 0,
    do: depth

  def refusals(%{} = attempt) do
    case Map.get(attempt, :deferral_depth) do
      depth when is_integer(depth) and depth > 0 -> depth
      _ -> nil
    end
  end

  def refusals(_attempt), do: nil

  # `DeployLedger.classify/1` has no clause for a map carrying no `:status` at
  # all — the reaper's `select:`-shaped map is exactly that — so the key is
  # checked HERE rather than letting a FunctionClauseError travel out of a
  # notification funnel that must never raise.
  defp abandoned_class?(row) do
    case Map.get(row, :status) do
      "failed" ->
        case DeployLedger.classify(row) do
          class when is_binary(class) -> String.starts_with?(class, @abandoned_prefix)
          _ -> false
        end

      _other ->
        false
    end
  end
end
