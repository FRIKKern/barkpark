defmodule BarkparkCloud.Workers.TokenExpiryWarningWorker do
  @moduledoc """
  cch-w30-bl — the PAT expiry warning, delivered to the token's OWNER.

  Runs daily on the `:maintenance` queue. Over every live `context = "pat"` row
  whose bounded `expires_at` falls inside the warning window
  (`warning_window_days/0` — SEVEN days), mails ONE email to the owning user and
  claims the row's one-shot budget so no later pass repeats it.

  ## THE RECIPIENT RULE, WHICH IS THE WHOLE POINT OF THIS MODULE

  A warning about a token's lifecycle goes ONLY to the token's owning principal
  — for a PAT, `user_token.user_id` — on the USER-SCOPED transactional path
  (`Notifications.deliver_token_expiring/3`: `team_id` nil, carrier `platform`),
  the same path `password_reset` / `email_verification` ride.

  IT MAY NOT GO THROUGH `Notifications.dispatch_event/3`, and this module never
  calls it. That function's recipient list is
  `for recipient <- team_member_emails(settings.team_id)` with no role
  predicate — its own docstring calls team-members-only "the data-exfiltration
  guard from Coolify's `EmailChannel.php`", which is the right guard for a
  TEAM-scoped fact and the wrong one here. A PAT carries BOTH a `user_id` and a
  `team_id`, and its `name` is a string the owner chose, so fanning this warning
  to the team publishes one member's credential inventory, the names they gave
  their tokens, and their rotation schedule to everyone else. Measured before
  this slice: dispatching `:token_expiring` on a 3-member team wrote 3 Delivery
  rows, one per member.

  There is a second, structural lock, and it is deliberately left in place:
  `token_expiring` is NOT an `EmailSettings` toggle column (wave 30's migration
  `20260804123000` dropped it — a TEAM toggle governing a USER-scoped fact) and
  is NOT on `Notifications`'s `@always_send` list, so the alert path applied to
  `:token_expiring` falls through `EmailSettings.event_enabled?/2`'s catch-all
  to `false` and sends nothing at all. (The forbidden function is never spelled
  with its parentheses anywhere in this file — the source-level assertion in
  `token_expiry_warning_worker_test.exs` greps for a CALL, and prose that looks
  like one would make that fence vacuous.) Re-adding either would silently re-open the fan-out; the negative test in
  `token_expiry_warning_worker_test.exs` is what reds if anyone does.

  ## THE WINDOW

  Seven days, stated once in `warning_window_days/0` and read from there by the
  scan. Chosen against the default PAT lifetime
  (`UserToken.pat_default_validity_days/0` — 30 days): a week is long enough to
  mint a replacement and swap it through a deploy pipeline, and short enough
  that the notice still reads as urgent rather than as noise arriving a month
  early. DAILY cadence, not hourly: the deadline is day-grained, the budget is
  claimed once per token, and an hourly sweep would buy nothing but load.

  ## READ BEFORE YOU SPEND

  The `expiry_warned_at` stamp is claimed AFTER the send, not before, and only
  when the send succeeded — the inverse of `TrialExpiryWorker`'s ordering and
  for the same reason it documents at length. The stamp is the ENTIRE budget for
  this warning and nothing reads it back, so burning it on a send that failed
  costs the owner their only notice with no surface that shows the loss. A
  failed send leaves the stamp NULL and the delivery row `failed`, so tomorrow's
  pass tries again — which is exactly what a must-arrive credential deadline
  wants.

  The claim is still atomic (`UPDATE … WHERE expiry_warned_at IS NULL`), so two
  overlapping passes send at most one extra email between them rather than one
  per pass forever. The `unique` window below collapses a slow run and the next
  tick into a single in-flight job.

  Idempotent and never raises: a run over nothing due returns zero counts, and a
  token whose owner row is missing is skipped rather than crashing the sweep.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3600, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  require Logger

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{User, UserToken}
  alias BarkparkCloud.Notifications

  @warning_window_days 7

  @doc """
  How far ahead of a PAT's `expires_at` the owner is warned, in WHOLE DAYS — 7.

  PUBLIC on purpose: this is the one statement of the window, and the worker's
  own scan derives its horizon from it, so "how far ahead we warn" and "who the
  scan selects" can never drift apart the way `TrialExpiryWorker`'s day count
  drifted from its threshold before cch-w50-s5 named it once.
  """
  @spec warning_window_days() :: pos_integer()
  def warning_window_days, do: @warning_window_days

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, run(DateTime.utc_now())}
  end

  @doc """
  Scan the due PATs once against `now`. Returns `%{warned: n, failed: n}`.
  Public so tests can drive it deterministically (the `perform/1` entry passes
  `DateTime.utc_now/0`).

  `now` is handed to `Accounts.pats_expiring_within/2` as well, so the working
  set and the stamp are read off ONE instant.
  """
  @spec run(DateTime.t()) :: %{warned: non_neg_integer(), failed: non_neg_integer()}
  def run(%DateTime{} = now) do
    now
    |> Accounts.pats_expiring_within(@warning_window_days * 86_400)
    |> Enum.reduce(%{warned: 0, failed: 0}, fn token, acc -> warn(acc, token, now) end)
  end

  # ONE token, ONE recipient. The address comes off the PRELOADED owner
  # association — `token.user.email` — and from nowhere else. There is no team
  # read anywhere in this function, which is what makes the recipient rule a
  # property of the code rather than a comment about it.
  defp warn(acc, %UserToken{user: %User{email: to}} = token, now)
       when is_binary(to) do
    case Notifications.deliver_token_expiring(to, token.name, token.expires_at) do
      {:ok, _} ->
        # Spend the budget only now that the mail is out. See the moduledoc.
        _ = Accounts.claim_pat_expiry_warning(token.id, now)
        %{acc | warned: acc.warned + 1}

      {:error, why} ->
        # The delivery row is already written `failed` by
        # `deliver_token_expiring/3`; the stamp stays NULL so tomorrow retries.
        Logger.warning(
          "TokenExpiryWarningWorker: warning for token #{token.id} failed: #{inspect(why)}"
        )

        %{acc | failed: acc.failed + 1}
    end
  end

  # A PAT whose owner row is gone (or whose email is somehow not a string) has
  # nobody to warn. Skipped, never guessed at: charter D362 forbids inventing a
  # recipient, and a team address is the exact substitution this module exists
  # to refuse.
  defp warn(acc, _token, _now), do: acc
end
