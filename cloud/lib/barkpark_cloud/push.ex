defmodule BarkparkCloud.Push do
  @moduledoc """
  Push-relay SPIKE (mobile charter D15) — device registration, the
  workspace → registered-member-devices fan-out, and one delivery's execution.
  The production relay BUILD is wave 2; everything here is severable by
  ROW-ABSENCE (see `Push.DevicePushToken`): no registration row → nothing
  fires. Zero feature flags, zero dead code.

  ## The pipeline

      instance chat_blocked webhook (signed t=<unix>,v1=<hex>)
        → POST /v1/relay/chat-blocked/:barkpark_id   (HMAC IS the auth)
        → enqueue_chat_blocked_fanout/2              (this module)
        → one Oban PushDeliveryWorker job PER registered device
        → Push.deliver/3 → the :push_adapter seam    (APNs/FCM in wave 2)

  ## Fan-out mapping (charter D15c — "the payload identifies no user")

  The D59h chat_blocked payload carries NO user id, and the payload's
  `workspace_id` is an INSTANCE-side workspace — Cloud stores no mapping for it,
  and instance workspace slugs are not unique across barkparks (the same
  ambiguity that ruled out dataset→sites resolution in charter D45). So the
  webhook's ROUTE, not its payload, names the instance: the receiver is
  per-barkpark (`/v1/relay/chat-blocked/:barkpark_id`, exactly the per-site
  content-publish receiver pattern), the signature over the barkpark's OWN
  stored secret proves the sender, and recipients resolve as:

      :barkpark_id (HMAC-verified) → barkparks row → owning team
        → team_memberships → users → unrevoked device_push_tokens

  Every registered device of every member of the owning team is notified — the
  needs-you ask is team-visible by design (any member may answer it), and
  member-level targeting (roles, mute lists) is explicitly wave-2 surface. The
  payload's `workspace_id` is used ONLY inside the deep link.

  ## Deep-link ruling (charter D15c, D59h — bound decision)

  The 5-field payload STANDS: `{session_id, title, workspace_id, blocked_since,
  ask_role}` — never message content, never tool input, and NO payload widening.
  The notification deep-links to the SESSION
  (`barkpark://sessions/<session_id>?workspace_id=<ws>`); the app
  follow-up-fetches the pending asks from the instance on tap. Rationale: the
  ask list is live state — any snapshot pushed through APNs/FCM would be stale
  by tap-time, and widening the payload would leak conversation content through
  two third-party push clouds for zero freshness gain.

  ## Wave-2 design notes (deliberately NOT built in the spike)

    * Instance-side wiring: provision the chat_blocked webhook row on the box
      via the admin relay (the `create_site` content-publish idiom), carrying
      `url: <cloud>/v1/relay/chat-blocked/<barkpark_id>` +
      `secret: Registry.mint_push_relay_secret/1`'s plaintext.
    * Real APNs/FCM adapters behind `Push.Adapter` (creds human-gate documented
      in `Push.Adapters.NotConfigured`).
    * Stale-token reaper: a periodic sweep revoking rows whose `last_used_at`
      is ancient. NOTE the delivery path already self-heals the loud half —
      `deliver/3` revokes a row the platform reports unregistered/invalid — so
      the reaper only collects devices that never get sends.
  """

  import Ecto.Query

  alias BarkparkCloud.Accounts.{TeamMembership, User}
  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Workers.PushDeliveryWorker

  # The D59h chat_blocked wire fields — the ONLY keys that survive into a job's
  # args and the notification's data map. Anything else an instance sends is
  # dropped here (no payload widening; bound deep-link ruling above).
  @chat_blocked_fields ~w(session_id title workspace_id blocked_since ask_role)

  ## Registration

  @doc """
  Register (or refresh) one device push token for `user` — the user-authed
  registration endpoint's core. Idempotent UPSERT on
  (user_id, platform, token): re-registering clears `revoked_at` (an app
  reinstall on the same device revives the row) and refreshes `metadata`.

  Returns `{:ok, %DevicePushToken{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec register_device_token(User.t(), map()) ::
          {:ok, DevicePushToken.t()} | {:error, Ecto.Changeset.t()}
  def register_device_token(%User{id: user_id}, attrs) when is_map(attrs) do
    metadata = if is_map(attrs["metadata"]), do: attrs["metadata"], else: %{}

    changeset =
      DevicePushToken.changeset(%DevicePushToken{}, %{
        platform: attrs["platform"],
        token: attrs["token"],
        metadata: metadata,
        user_id: user_id
      })

    Repo.insert(changeset,
      on_conflict: [set: [revoked_at: nil, metadata: metadata, updated_at: DateTime.utc_now()]],
      conflict_target: [:user_id, :platform, :token],
      returning: true
    )
  end

  @doc """
  Every live (unrevoked) device registration across the members of the team
  owning `barkpark` — the fan-out recipient set. See the mapping in the
  moduledoc; tested in `push_relay_receiver_test.exs` (cross-team isolation,
  revoked exclusion, row-absence inertness).
  """
  @spec active_device_tokens_for_barkpark(Barkpark.t()) :: [DevicePushToken.t()]
  def active_device_tokens_for_barkpark(%Barkpark{team_id: team_id}) do
    from(t in DevicePushToken,
      join: m in TeamMembership,
      on: m.user_id == t.user_id,
      where: m.team_id == ^team_id and is_nil(t.revoked_at),
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  ## Fan-out

  @doc """
  Fan a verified chat_blocked webhook out to the owning team's registered
  devices: one `PushDeliveryWorker` job per unrevoked device row, args carrying
  ONLY the D59h 5-field payload. Returns `{:ok, enqueued_count}` — 0 when no
  device is registered (row-absence severability: the relay is inert), or
  `{:error, :invalid_payload}` when `session_id` is missing/blank (nothing to
  deep-link to).
  """
  @spec enqueue_chat_blocked_fanout(Barkpark.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_payload}
  def enqueue_chat_blocked_fanout(%Barkpark{} = barkpark, payload) when is_map(payload) do
    case payload["session_id"] do
      session_id when is_binary(session_id) and session_id != "" ->
        trimmed = Map.take(payload, @chat_blocked_fields)

        jobs =
          barkpark
          |> active_device_tokens_for_barkpark()
          |> Enum.map(fn device ->
            PushDeliveryWorker.new(%{
              "device_push_token_id" => device.id,
              "event" => "chat_blocked",
              "payload" => trimmed
            })
          end)

        Oban.insert_all(jobs)
        {:ok, length(jobs)}

      _ ->
        {:error, :invalid_payload}
    end
  end

  ## Delivery (the worker's core)

  @doc """
  Execute ONE delivery to ONE device — `PushDeliveryWorker.perform/1`'s body,
  on `ChatNotificationWorker`'s exact verdict contract:

    * `:ok` — the adapter accepted the send (2xx); `last_used_at` stamped.
    * `{:cancel, reason}` — TERMINAL, no retry: the row is gone/revoked, the
      platform reports the token dead (`:unregistered` / `:invalid_token` —
      the row is REVOKED here, self-healing the registry), or no adapter
      credentials exist (`:not_configured`).
    * `{:error, reason}` — transport/5xx; Oban re-drives on [1s, 5s, 30s].
  """
  @spec deliver(binary(), String.t(), map()) :: :ok | {:cancel, term()} | {:error, term()}
  def deliver(device_push_token_id, event, payload) do
    case Repo.get(DevicePushToken, device_push_token_id) do
      nil ->
        {:cancel, :token_gone}

      %DevicePushToken{revoked_at: %DateTime{}} ->
        {:cancel, :token_revoked}

      %DevicePushToken{} = device ->
        case adapter().send_push(device, notification(event, payload)) do
          {:ok, _} ->
            touch_last_used(device)
            :ok

          {:error, reason} when reason in [:unregistered, :invalid_token] ->
            revoke(device)
            {:cancel, reason}

          {:error, :not_configured} ->
            {:cancel, :not_configured}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  The platform-neutral notification map an adapter translates into an APNs/FCM
  request. Encodes the bound deep-link ruling (moduledoc): `deep_link` targets
  the SESSION, `data` carries the D59h 5 fields VERBATIM and nothing else — the
  app follow-up-fetches pending asks on tap.
  """
  @spec notification(String.t(), map()) :: map()
  def notification("chat_blocked", payload) do
    session_id = payload["session_id"]
    workspace_id = payload["workspace_id"]

    suffix =
      if is_binary(workspace_id) and workspace_id != "" do
        "?workspace_id=" <> URI.encode_www_form(workspace_id)
      else
        ""
      end

    %{
      "title" => "Barkpark needs you",
      "body" => payload["title"] || "A chat session is waiting on your answer",
      "deep_link" => "barkpark://sessions/#{session_id}#{suffix}",
      "data" => Map.take(payload, @chat_blocked_fields)
    }
  end

  defp touch_last_used(device) do
    device
    |> Ecto.Changeset.change(last_used_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
    |> Repo.update()
  end

  defp revoke(device) do
    device
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
    |> Repo.update()
  end

  defp adapter do
    Application.get_env(
      :barkpark_cloud,
      :push_adapter,
      BarkparkCloud.Push.Adapters.NotConfigured
    )
  end
end
