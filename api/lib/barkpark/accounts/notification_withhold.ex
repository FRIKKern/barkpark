defmodule Barkpark.Accounts.NotificationWithhold do
  @moduledoc """
  The one funnel through which a WITHHELD account notification becomes a VISIBLE
  audit event.

  ## The definition, borrowed verbatim from the cloud twin

  `BarkparkCloud.Notifications.Withhold` (wave 32, charter D363) defines a
  **silent withhold** as a branch where the system was positioned to send a
  notification, does not send it, and writes nothing to the surface built to
  answer *"was I notified?"*. The lens matters there and it matters here: the
  ABSENCE OF A PERSON is not a withhold; a decision the system made FOR a person,
  without telling them, is.

  This module is the api-side counterpart. The mechanism differs — cloud
  dispatches and then decides to withhold, while here a controller branch simply
  never reaches the notifier — but the vocabulary is deliberately the SAME, so the
  two apps say the same words for the same thing. Two implementations of one rule
  is this repo's most-repeated defect; this is one rule with two call sites.

  ## Where the trace goes: the audit log, not a second delivery table

  api/ has no `Delivery` table and does not grow one for this. It already has a
  person-facing, queryable, append-only trace that ships to the SIEM —
  `Barkpark.Audit` — and the auth flow already emits into it (`login_failed`,
  `password_reset`, `mfa_failed`, `logout`, …). A withhold is one more `auth`
  event on that same surface.

  ## The two reasons, and why only one of them writes a row

    * `:no_recipient_by_construction` — the address maps to no user. There is
      nobody the notification was withheld FROM, so there is nobody to show a row
      to. CONSENTED: it returns a count of `0` and writes nothing. This mirrors
      the cloud funnel, which returns `0` for its own zero-recipient cases rather
      than inventing a recipient. It also means the anti-enumeration branches
      cannot be turned into an attacker-driven write amplifier, and that a probed
      address is never persisted.

    * `:dispatch_crashed` — a REAL, KNOWN user was positioned to receive a
      notification and an internal failure stopped it. This is the genuine silent
      withhold, and it writes the audit event.

  Keeping both in one closed vocabulary is the point: the caller must say which
  case it is, so "we chose not to email this person" and "email is broken for this
  person" can never again be the same silence.
  """
  require Logger

  alias Barkpark.Audit

  # THE CLOSED VOCABULARY. Both atoms are cloud's, not new coinages. Cited by
  # SYMBOL rather than by line, because a line anchor is the part that rots:
  # `BarkparkCloud.Notifications.deliver_fleet_digest/1` passes
  # `:no_recipient_by_construction` to `Withhold.record/4`, and
  # `BarkparkCloud.Notifications.dispatch_event/3` passes `:dispatch_crashed`.
  @reasons [:no_recipient_by_construction, :dispatch_crashed]

  # The account notifications this funnel can speak about — every `deliver_*` on
  # `Barkpark.Accounts.UserNotifier`.
  @notifications ~w(confirmation magic_link reset already_registered)

  @audit_action "notification_withheld"

  @doc "The closed reason vocabulary."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc "The notification kinds this funnel can speak about."
  @spec notifications() :: [String.t()]
  def notifications, do: @notifications

  @doc """
  Record that `notification` was not sent, for `reason`.

  Returns `{:ok, count}` — the number of audit events written, so a caller can
  assert on it. `0` is the honest answer for a consented withhold; it is never
  the answer for an unrecognised reason, which is loud instead (a quiet zero
  there would rebuild the very defect this module exists to remove).

  Options:

    * `:user_id` — the user the notification was withheld from. Required in
      spirit for `:dispatch_crashed`: a withhold from nobody is a contradiction.
    * `:detail` — a short machine-ish tag for what failed, e.g. `"token_mint_failed"`.
  """
  @spec record(String.t(), atom(), keyword()) :: {:ok, non_neg_integer()}
  def record(notification, reason, opts \\ [])

  # CONSENTED — the absence of a person, not a decision against one. No row, and
  # deliberately no attacker-driven write: the probed address is not persisted.
  def record(notification, :no_recipient_by_construction, _opts)
      when notification in @notifications do
    {:ok, 0}
  end

  def record(notification, :dispatch_crashed, opts)
      when notification in @notifications do
    user_id = Keyword.get(opts, :user_id)
    detail = Keyword.get(opts, :detail)

    # A `:dispatch_crashed` with no user is a withhold from nobody. Refuse to
    # write a row that says a person was involved who was not — the cloud funnel
    # makes the same refusal about synthetic recipients — but say so loudly.
    if is_nil(user_id) do
      Logger.error(
        "[notification_withheld] #{notification} withheld as :dispatch_crashed with no user_id — " <>
          "not recorded, because a row naming nobody answers nobody's question"
      )

      {:ok, 0}
    else
      emit(notification, user_id, detail)
    end
  end

  def record(notification, reason, _opts) do
    # Neither an unknown notification nor an unknown reason may pass quietly.
    Logger.error(
      "[notification_withheld] refusing an unrecognised withhold: " <>
        "notification=#{inspect(notification)} reason=#{inspect(reason)}. " <>
        "Known notifications #{inspect(@notifications)}; known reasons #{inspect(@reasons)}. " <>
        "Add it to Barkpark.Accounts.NotificationWithhold before calling."
    )

    {:ok, 0}
  end

  # Best-effort, exactly like the auth flow's own audit helper: the state change
  # this accompanies has already happened, so an audit-bus hiccup must never turn
  # a withheld email into a failed request.
  defp emit(notification, user_id, detail) do
    metadata =
      %{"notification" => notification, "reason" => "dispatch_crashed"}
      |> maybe_put("detail", detail)

    Audit.emit(%{
      category: "auth",
      action: @audit_action,
      subject: notification,
      actor_type: "system",
      actor_id: user_id,
      metadata: metadata
    })

    {:ok, 1}
  rescue
    error ->
      Logger.error(
        "[notification_withheld] audit emit crashed for #{notification}: " <>
          Exception.message(error)
      )

      {:ok, 0}
  catch
    _, _ -> {:ok, 0}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))
end
