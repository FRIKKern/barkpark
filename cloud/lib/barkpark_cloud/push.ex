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

  ## Built in the wave-2 relay BUILD

    * Instance-side wiring: `Registry.provision_push_relay_webhook/2` creates
      the box's `chat_blocked` webhook row over the admin relay, pointed at
      `<cloud>/v1/relay/chat-blocked/<barkpark_id>` and signed with
      `Registry.mint_push_relay_secret/1`'s plaintext.
    * Real adapters behind `Push.Adapter`: `Adapters.APNS` (HTTP/2 + ES256
      provider token) and `Adapters.FCM` (HTTP v1 + service-account OAuth2),
      selected PER PLATFORM by `adapter_for/1` iff their credentials exist.
      With none, `Adapters.NotConfigured` cancels terminally — and that module's
      moduledoc is the exact credential gate an operator opens.

  ## Still deliberately NOT built

    * Stale-token reaper: a periodic sweep revoking rows whose `last_used_at`
      is ancient. NOTE the delivery path already self-heals the loud half —
      `deliver/3` revokes a row the platform reports unregistered/invalid — so
      the reaper only collects devices that never get sends.
    * A pooled, multiplexed APNs connection (see `Push.HTTP.Mint`): worth doing
      when fan-out volume justifies a supervised pool, not before.
  """

  import Ecto.Query

  require Logger

  alias BarkparkCloud.Accounts.{TeamMembership, User}
  alias BarkparkCloud.Push.Adapters
  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Workers.PushDeliveryWorker

  # The D59h chat_blocked wire fields — the ONLY keys that survive into a job's
  # args and the notification's data map. Anything else an instance sends is
  # dropped here (no payload widening; bound deep-link ruling above).
  @chat_blocked_fields ~w(session_id title workspace_id blocked_since ask_role)

  # Per-user device-row cap (wave-2 hardening, adversarial review of PR #6030):
  # without one, an authed member can accrete unlimited rows, bloating every
  # webhook fan-out. 20 rows is far above any real household of devices while
  # keeping the worst-case per-user fan-out bounded. Enforcement is
  # EVICTION, not 422 — a 422 would reject the user's NEWEST real device in
  # favor of stale rows, exactly backwards; evicting revoked-first, then
  # stalest, silently self-heals accretion while the active device keeps
  # working.
  @max_devices_per_user 20

  ## Registration

  @doc "The per-user device-row cap enforced by `register_device_token/2`."
  def max_devices_per_user, do: @max_devices_per_user

  @doc """
  Register (or refresh) one device push token for `user` — the user-authed
  registration endpoint's core. Idempotent UPSERT on
  (user_id, platform, token): re-registering clears `revoked_at` (an app
  reinstall on the same device revives the row) and refreshes `metadata`.

  Caps the user at #{@max_devices_per_user} rows: when a NEW registration
  pushes past the cap, surplus rows are evicted — revoked tombstones first,
  then the stalest by last-use (falling back to insertion age) — so the row
  just registered always survives. Re-registering an existing row never
  evicts (the count is unchanged).

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

    result =
      Repo.insert(changeset,
        on_conflict: [set: [revoked_at: nil, metadata: metadata, updated_at: DateTime.utc_now()]],
        conflict_target: [:user_id, :platform, :token],
        returning: true
      )

    with {:ok, device} <- result do
      enforce_device_cap(user_id, device.id)
      {:ok, device}
    end
  end

  # Trim the user back to the cap after an upsert. Two statements, no
  # transaction on purpose: a crash between them leaves at most cap+1 rows and
  # the next registration self-heals. Victim order: revoked tombstones first
  # (dead weight — no delivery ever selects them), then least-recently-used
  # (`last_used_at`, falling back to `inserted_at` for rows that never got a
  # send). The just-registered row is always excluded.
  defp enforce_device_cap(user_id, keep_id) do
    count = Repo.aggregate(from(t in DevicePushToken, where: t.user_id == ^user_id), :count)
    overflow = count - @max_devices_per_user

    if overflow > 0 do
      victim_ids =
        from(t in DevicePushToken,
          where: t.user_id == ^user_id and t.id != ^keep_id,
          order_by: [
            asc: fragment("? IS NULL", t.revoked_at),
            asc: coalesce(t.last_used_at, t.inserted_at)
          ],
          limit: ^overflow,
          select: t.id
        )
        |> Repo.all()

      Repo.delete_all(from(t in DevicePushToken, where: t.id in ^victim_ids))
    end

    :ok
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

  Jobs are inserted ONE AT A TIME via `Oban.insert/2` — deliberately not
  `Oban.insert_all/2`, which skips unique enforcement on the OSS engine — so
  `PushDeliveryWorker`'s args-uniqueness window dedupes a REPLAYED webhook
  (identical signed request re-sent inside the HMAC acceptance window, or an
  instance-side at-least-once redelivery): the replay's jobs all conflict with
  the originals and `enqueued_count` reports only NEW jobs. Fan-out sets are
  small (one team's member devices), so per-row inserts cost nothing real.
  """
  @spec enqueue_chat_blocked_fanout(Barkpark.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_payload}
  def enqueue_chat_blocked_fanout(%Barkpark{} = barkpark, payload) when is_map(payload) do
    case payload["session_id"] do
      session_id when is_binary(session_id) and session_id != "" ->
        trimmed = Map.take(payload, @chat_blocked_fields)

        enqueued =
          barkpark
          |> active_device_tokens_for_barkpark()
          |> Enum.count(fn device ->
            %{
              "device_push_token_id" => device.id,
              "event" => "chat_blocked",
              "payload" => trimmed
            }
            |> PushDeliveryWorker.new()
            |> Oban.insert()
            |> record_insert_result(%{
              device_push_token_id: device.id,
              barkpark_id: barkpark.id,
              session_id: trimmed["session_id"]
            })
          end)

        {:ok, enqueued}

      _ ->
        {:error, :invalid_payload}
    end
  end

  @doc """
  Classify ONE `Oban.insert/2` verdict from the fan-out: `true` when a NEW job
  was enqueued, `false` otherwise. The `{:error, _}` branch also LOGS.

  Public (and `@doc false`-adjacent — it is an internal seam, not API) for one
  reason: it is the fan-out's whole failure policy, and `Oban.insert/2` cannot
  be made to fail on demand inside a test that is otherwise real. Extracting it
  makes the policy directly provable instead of untestable-and-therefore-untested
  — which is exactly how it shipped silently wrong in the first place.

  ## Why an insert failure was worth extracting

  Before the wave-2 relay build, `{:error, _}` was folded into the same `false`
  as a dedupe conflict (PR #6097 review advisory). The consequences were
  invisible by construction: the receiver still answered `202` with a
  SILENTLY UNDERCOUNTED `enqueued`, so a notification that was never enqueued
  left no trace in the response, in the job table, or in the log. A dropped
  needs-you ping is precisely the failure this relay exists to prevent.

  It stays NON-FATAL — one failed insert must not abort the fan-out to the
  user's other devices — but it is now loud, and the log names the device row,
  the barkpark and the session, so a missing notification is traceable to the
  device that lost it.
  """
  @spec record_insert_result({:ok, Oban.Job.t()} | {:error, term()}, map()) :: boolean()
  def record_insert_result({:ok, %Oban.Job{conflict?: true}}, _context) do
    # Dedupe: an EXPECTED, silent outcome — a replayed webhook inside the
    # worker's uniqueness window. Not a failure; nothing to say.
    false
  end

  def record_insert_result({:ok, %Oban.Job{}}, _context), do: true

  def record_insert_result({:error, reason}, context) do
    # WARNING, not error: it matches `Registry.maybe_register_content_webhook/3`'s
    # level for the same class of event (a best-effort side channel that did not
    # take) and keeps prod error budgets meaningful. The severity that matters
    # is that it is SAID AT ALL — before this, nothing was.
    Logger.warning(
      "push fan-out: could not enqueue delivery " <>
        "device_push_token_id=#{context[:device_push_token_id]} " <>
        "barkpark_id=#{context[:barkpark_id]} " <>
        "session_id=#{inspect(context[:session_id])} reason=#{inspect(reason)}"
    )

    false
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
        case adapter_for(device.platform).send_push(device, notification(event, payload)) do
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

  @doc """
  The `Push.Adapter` module that will handle a send to `platform`, right now.

  Resolution (wave-2 relay build):

    * `config :barkpark_cloud, :push_adapter, SomeModule` — an explicit
      OVERRIDE, used by every platform. config/test.exs pins
      `PushFakeAdapter` here, so the worker suite is untouched by this change.
    * `:auto` (the config.exs default, and prod) — per platform, the REAL
      adapter iff its credentials are present, else `NotConfigured`.

  Per-platform, not global, because a device row is `apns` XOR `fcm`: shipping
  Android first must not make iOS rows silently take the FCM path, and one
  platform's missing credential must not disable the other.

  This IS the credential half of severability, and it is the same shape as the
  row half: absence, not a flag. Nothing to switch on at deploy — the relay
  starts delivering on the first send after a credential exists.
  """
  @spec adapter_for(String.t() | nil) :: module()
  def adapter_for(platform) do
    case Application.get_env(:barkpark_cloud, :push_adapter, :auto) do
      :auto -> auto_adapter(platform)
      module when is_atom(module) -> module
    end
  end

  defp auto_adapter("apns") do
    if Adapters.APNS.configured?(), do: Adapters.APNS, else: Adapters.NotConfigured
  end

  defp auto_adapter("fcm") do
    if Adapters.FCM.configured?(), do: Adapters.FCM, else: Adapters.NotConfigured
  end

  defp auto_adapter(_other), do: Adapters.NotConfigured

  @doc """
  Which platforms this control plane can actually deliver to, right now —
  `%{"apns" => bool, "fcm" => bool}`. The operator-facing answer to "is the
  credential gate open?", and the thing an ops probe should read instead of
  guessing from the absence of notifications.
  """
  @spec credential_status() :: %{String.t() => boolean()}
  def credential_status do
    %{
      "apns" => adapter_for("apns") != Adapters.NotConfigured,
      "fcm" => adapter_for("fcm") != Adapters.NotConfigured
    }
  end
end
