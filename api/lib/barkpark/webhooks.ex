defmodule Barkpark.Webhooks do
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content.Scope
  alias Barkpark.Webhooks.{Webhook, Delivery}

  @doc """
  List webhooks for a dataset, optionally scoped to a workspace/project.

  `opts` may carry `:workspace_id` / `:project_id`; when present the list is
  filtered through `Content.Scope.scope_to_workspace/3` IN ADDITION TO the
  dataset filter — the same hard tenant boundary the Content reads enforce.
  A `nil`/absent `workspace_id` keeps the pre-tenancy unscoped behaviour.
  """
  def list_webhooks(dataset, opts \\ []) do
    Webhook
    |> where([w], w.dataset == ^dataset)
    |> scope(opts)
    |> order_by([w], asc: w.name)
    |> Repo.all()
  end

  @doc """
  Fetch a webhook by id, optionally scoped to a workspace/project.

  `opts` may carry `:workspace_id` / `:project_id`; when present the lookup is
  scoped so a workspace-A member cannot fetch (and therefore cannot update or
  delete) a workspace-B webhook by guessing its id — out-of-scope ids return
  `{:error, :not_found}`. A `nil`/absent `workspace_id` keeps the unscoped
  lookup (internal callers / pre-tenancy).
  """
  def get_webhook(id, opts \\ []) do
    # Guard the :binary_id cast: a non-UUID id (e.g. GET /v1/webhooks/:ds/garbage)
    # would raise Ecto.CastError → 500. A malformed id matches no row → not_found.
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        query =
          Webhook
          |> where([w], w.id == ^uuid)
          |> scope(opts)

        case Repo.one(query) do
          nil -> {:error, :not_found}
          webhook -> {:ok, webhook}
        end
    end
  end

  @doc """
  Create a webhook, stamping it with the caller's workspace/project scope.

  The tenant a webhook is owned by is SERVER-AUTHORITATIVE: any client-supplied
  scope key in `attrs` is dropped first, then `workspace_id`/`project_id` are
  stamped from `opts` (the resolved `ScopeHelpers.scope_opts`). A wsA-scoped
  admin therefore cannot POST a hook into wsB (cross-tenant event exfiltration).
  An absent `workspace_id` in `opts` leaves the row unscoped (pre-tenancy /
  internal callers).
  """
  def create_webhook(attrs, opts \\ []) do
    %Webhook{}
    |> Webhook.changeset(stamp_scope(attrs, opts))
    |> Repo.insert()
  end

  # Scope-id keys a client must never set — dropped (string AND atom form)
  # before the scope is stamped from server-resolved opts.
  @scope_keys [
    "workspace_id",
    "project_id",
    "dataset_id",
    :workspace_id,
    :project_id,
    :dataset_id
  ]

  # Drop client-supplied scope keys, THEN stamp workspace_id/project_id from
  # opts — override, never defer. Mirrors `Content.WriteScope.put_scope_attrs/2`
  # (minus the Default fallback, which the webhook write path does not need).
  defp stamp_scope(attrs, opts) do
    attrs
    |> Map.drop(@scope_keys)
    |> maybe_put_scope("workspace_id", Keyword.get(opts, :workspace_id))
    |> maybe_put_scope("project_id", Keyword.get(opts, :project_id))
  end

  defp maybe_put_scope(attrs, _key, nil), do: attrs
  defp maybe_put_scope(attrs, key, value), do: Map.put(attrs, key, value)

  def update_webhook(%Webhook{} = webhook, attrs) do
    # Scope + secret are IMMUTABLE on update. Drop the client scope keys so a
    # hook can't be moved across tenants (the stored row's scope stands), and
    # drop `secret` so the signing secret rotates ONLY through rotate_secret/3
    # (which also sets the previous-secret validity window). Name/url/events/
    # types/active update normally.
    attrs = attrs |> Map.drop(@scope_keys) |> Map.drop(["secret", :secret])

    webhook
    |> Webhook.changeset(attrs)
    |> Repo.update()
  end

  def delete_webhook(%Webhook{} = webhook) do
    # A concurrent double-DELETE would raise Ecto.StaleEntryError (→ 500).
    # stale_error_field turns the race into {:error, :not_found} (rendered 404).
    case Repo.delete(webhook, stale_error_field: :id) do
      {:error, cs} -> if stale?(cs), do: {:error, :not_found}, else: {:error, cs}
      ok -> ok
    end
  end

  @doc """
  Select the active webhooks that fire for an event, optionally scoped to a
  workspace/project.

  `opts` may carry `:workspace_id` / `:project_id` (threaded from the changed
  doc's scope). When present, the selection is filtered through
  `Content.Scope.scope_to_workspace/3` so a content change in workspace B never
  selects workspace A's webhooks — the cross-tenant delivery leak guard. The
  dataset + events + types filters are unchanged; this ADDS the workspace
  envelope around them. A `nil`/absent `workspace_id` keeps the pre-tenancy
  unscoped behaviour (matches every webhook in the dataset).
  """
  def active_webhooks_for(dataset, event, type, opts \\ []) do
    Webhook
    |> where([w], w.dataset == ^dataset and w.active == true)
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.events, w.events, ^event))
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.types, w.types, ^type))
    |> scope(opts)
    |> Repo.all()
  end

  # Apply the workspace/project tenant boundary from `opts`. Nil-safe via
  # Content.Scope: an absent workspace_id returns the query untouched.
  defp scope(query, opts) do
    Scope.scope_to_workspace_or_global(
      query,
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
  end

  @doc """
  Rotate the primary secret. The old secret moves to `previous_secret` and
  remains valid for `ttl_seconds` (default 86400 = 24h). Existing receivers
  can keep verifying with the old secret until it expires.
  """
  def rotate_secret(%Webhook{} = webhook, new_secret, ttl_seconds \\ 86_400)
      when is_binary(new_secret) do
    expires_at = DateTime.utc_now() |> DateTime.add(ttl_seconds, :second)

    # `:previous_secret` / `:previous_secret_expires_at` are not castable (a
    # client must never set them) — the rotation path is their sole writer, so
    # it stamps them with Ecto.Changeset.change/2 on top of the cast `:secret`.
    webhook
    |> Webhook.changeset(%{"secret" => new_secret})
    |> Ecto.Changeset.change(%{
      previous_secret: webhook.secret,
      previous_secret_expires_at: expires_at
    })
    |> Repo.update()
  end

  @doc """
  Claim an (endpoint_id, event_id) delivery slot. Returns
  `{:ok, delivery}` if this is the first claim, or
  `{:error, :already_delivered}` if a row already exists for this pair.
  Uses the UNIQUE(endpoint_id, event_id) constraint for atomicity.
  """
  def claim_delivery(endpoint_id, event_id) when is_integer(event_id) do
    case Repo.insert(
           Delivery.changeset(%Delivery{}, %{
             endpoint_id: endpoint_id,
             event_id: event_id,
             status: "pending"
           }),
           on_conflict: :nothing,
           conflict_target: [:endpoint_id, :event_id]
         ) do
      {:ok, %Delivery{id: nil}} -> {:error, :already_delivered}
      {:ok, %Delivery{} = d} -> {:ok, d}
      {:error, _} = err -> err
    end
  end

  @doc """
  Insert a durable MEDIA delivery row (`source_kind: "media"`).

  Media endpoints are config-driven (`:media_webhooks`), so there is no `webhooks`
  row (`endpoint_id` NULL) and no `mutation_events` row (`event_id` NULL). The
  resumable unit — the target url, its signing secret, and the already-encoded
  JSON body — is snapshotted into `payload_snapshot`, because media's source event
  is gone by design (`media.deleted` passes the file struct at delete time). The
  `RetryWorker` / `StuckDeliverySweeper` rebuild the media attempt FROM this
  snapshot, branching on `source_kind`. Never deduped (every media delivery is its
  own row — a lifecycle event fires once and is never re-broadcast).
  """
  def create_media_delivery(payload_snapshot) when is_map(payload_snapshot) do
    %Delivery{}
    |> Delivery.changeset(%{
      source_kind: "media",
      status: "pending",
      attempts: 0,
      payload_snapshot: payload_snapshot
    })
    |> Repo.insert()
  end

  def mark_delivered(%Delivery{} = d, status_code, attempts, latency_ms \\ nil) do
    result =
      d
      |> Delivery.changeset(%{
        status: "ok",
        last_status_code: status_code,
        attempts: attempts,
        last_latency_ms: latency_ms
      })
      |> Repo.update()

    # A successful delivery clears the consecutive-failure streak so a healthy
    # endpoint that had transient blips is never auto-disabled — the counter is
    # CONSECUTIVE, reset-on-success, not a lifetime total.
    reset_endpoint_failures(d.endpoint_id)
    result
  end

  def mark_giveup(%Delivery{} = d, status_code, reason, attempts, latency_ms \\ nil) do
    result =
      d
      |> Delivery.changeset(%{
        status: "failed_giveup",
        last_status_code: status_code,
        last_error_text: reason,
        attempts: attempts,
        last_latency_ms: latency_ms
      })
      |> Repo.update()

    # `mark_giveup/5` is the single choke point for a TRUE terminal give-up
    # (permanent 4xx, SSRF block, or retry exhaustion — post-#1008 classification,
    # so retried 429/408/425 that later succeed never reach here). Count it toward
    # the endpoint's consecutive-failure streak, auto-disabling past the threshold.
    record_endpoint_failure(d.endpoint_id, reason)
    result
  end

  # Default consecutive-failure count that auto-disables an endpoint. Overridable
  # via `config :barkpark, :webhook_auto_disable_threshold, N` (tests set it low).
  @default_auto_disable_threshold 20

  @doc """
  The consecutive terminal-give-up count at which an endpoint is auto-disabled.
  """
  def auto_disable_threshold do
    Application.get_env(
      :barkpark,
      :webhook_auto_disable_threshold,
      @default_auto_disable_threshold
    )
  end

  @doc """
  Reset an endpoint's consecutive-failure counter to 0 (called on every
  successful delivery). Gated on `> 0` so a healthy endpoint's steady stream of
  successes issues no needless writes.
  """
  # A media delivery (`source_kind: "media"`) carries no `endpoint_id` — its
  # endpoints are config-driven, not `webhooks` rows — so there is no
  # consecutive-failure streak to reset (and `w.id == ^nil` is a forbidden Ecto
  # comparison). No-op for those.
  def reset_endpoint_failures(nil), do: {0, nil}

  def reset_endpoint_failures(endpoint_id) do
    from(w in Webhook, where: w.id == ^endpoint_id and w.consecutive_failures > 0)
    |> Repo.update_all(set: [consecutive_failures: 0])
  end

  @doc """
  Record a TRUE terminal give-up against an endpoint: atomically increment its
  `consecutive_failures`, and auto-disable it once the streak crosses the
  configured threshold. The increment uses a single `UPDATE ... RETURNING` so
  concurrent deliveries can't lose a count, and the auto-disable write is gated
  on `active == true` so it stamps `auto_disabled_at` / `disable_reason` exactly
  once (idempotent — a later give-up on an already-disabled row is a no-op).
  """
  # Media deliveries carry no `endpoint_id` (config-driven endpoints, no
  # `webhooks` row), so there is nothing to count against and nothing to
  # auto-disable. No-op — a config endpoint can't be auto-disabled.
  def record_endpoint_failure(nil, _reason), do: {:ok, 0}

  def record_endpoint_failure(endpoint_id, reason) do
    {_, rows} =
      from(w in Webhook, where: w.id == ^endpoint_id, select: w.consecutive_failures)
      |> Repo.update_all(inc: [consecutive_failures: 1])

    case rows do
      [count] when is_integer(count) and count >= 0 ->
        if count >= auto_disable_threshold(),
          do: auto_disable_endpoint(endpoint_id, count, reason)

        {:ok, count}

      _ ->
        # Endpoint row is gone (deleted mid-flight) — nothing to count against.
        {:ok, 0}
    end
  end

  # Flip the endpoint inactive and stamp the auto-disable metadata. The
  # `active == true` guard makes this idempotent: only the FIRST give-up that
  # crosses the threshold performs the flip (and returns 1 updated row), so
  # `auto_disabled_at` isn't re-stamped on every subsequent failure. Disabled
  # endpoints drop out of `active_webhooks_for/4`, so no further delivery
  # attempts are made against a dead endpoint.
  defp auto_disable_endpoint(endpoint_id, count, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    disable_reason = build_disable_reason(count, reason)

    from(w in Webhook, where: w.id == ^endpoint_id and w.active == true)
    |> Repo.update_all(
      set: [active: false, auto_disabled_at: now, disable_reason: disable_reason, updated_at: now]
    )
  end

  # Human-readable disable reason, bounded so a long transport error can't
  # overflow the `disable_reason` string column.
  defp build_disable_reason(count, reason) do
    detail = reason |> to_string() |> String.slice(0, 180)
    "auto-disabled after #{count} consecutive delivery failures (last: #{detail})"
  end

  @doc """
  Re-enable an auto-disabled (or manually disabled) endpoint — the write path the
  console webhook panel's toggle calls. Fully restores the endpoint to a clean
  deliverable state: `active: true`, `consecutive_failures: 0`, and clears the
  `auto_disabled_at` / `disable_reason` stamps. Idempotent for an already-active
  endpoint (writes it back to the same clean state).
  """
  def reenable_webhook(%Webhook{} = webhook) do
    webhook
    |> Ecto.Changeset.change(%{
      active: true,
      consecutive_failures: 0,
      auto_disabled_at: nil,
      disable_reason: nil
    })
    |> Repo.update()
  end

  @doc """
  Fence a `pending` delivery for its NEXT attempt and enqueue a SCHEDULED
  `RetryWorker` job to re-drive it after `delay_ms`.

  Replaces the dispatcher's in-task `Process.sleep` backoff: instead of parking
  a bounded `WebhookDeliverySupervisor` slot for the whole backoff window, the
  retrying delivery persists its next-attempt intent here and RETURNS, so the
  slot is freed immediately (no head-of-line-blocking of healthy endpoints under
  a retry storm).

  The fence is a CAS on `updated_at` — the SAME token `StuckDeliverySweeper`
  guards on — advancing it to a fresh value and stamping `attempts: n`:

    * Sharing the `updated_at` fence makes a scheduled retry and a concurrent
      crash-sweep MUTUALLY EXCLUSIVE — whichever bumps it first wins, the other's
      CAS misses, so the two can never both fire (no double-delivery).
    * `attempts: n` records progress so the resumed `RetryWorker` knows which
      attempt to run next and the `max_attempts` bound holds across scheduled
      hops.

  Returns `{:ok, job}` when the fence CAS wins and the job is enqueued,
  `{:error, :superseded}` when another writer already claimed/terminalised the
  row, or `{:error, reason}` on an enqueue failure.
  """
  def schedule_retry(%Delivery{} = delivery, n, delay_ms)
      when is_integer(n) and n >= 1 and is_integer(delay_ms) and delay_ms >= 0 do
    fence = DateTime.utc_now()

    {claimed, _} =
      from(d in Delivery,
        where:
          d.id == ^delivery.id and d.status == "pending" and
            d.updated_at == ^delivery.updated_at
      )
      |> Repo.update_all(set: [attempts: n, updated_at: fence])

    case claimed do
      1 ->
        %{
          "delivery_id" => delivery.id,
          "attempt" => n,
          "fence" => DateTime.to_iso8601(fence)
        }
        |> Barkpark.Webhooks.RetryWorker.new(
          scheduled_at: DateTime.add(fence, delay_ms, :millisecond)
        )
        |> Oban.insert()

      0 ->
        {:error, :superseded}
    end
  end

  def get_delivery(endpoint_id, event_id) do
    Delivery
    |> where([d], d.endpoint_id == ^endpoint_id and d.event_id == ^event_id)
    |> Repo.one()
  end

  @default_delivery_limit 25
  @max_delivery_limit 100

  @doc """
  List an endpoint's recent deliveries, newest-first by `inserted_at` (ties
  broken by `id` so the order is total and stable).

  `opts[:limit]` is CLAMPED to `1..#{@max_delivery_limit}` at this context
  boundary — the #841/#846 first-page-truncation class of bug lives at exactly
  this seam: an absent limit falls back to #{@default_delivery_limit}, a
  negative/zero limit clamps up to 1, and an oversized limit clamps down to
  #{@max_delivery_limit}. Callers therefore cannot under- or over-fetch by
  passing a garbage page size.
  """
  def list_deliveries(endpoint_id, opts \\ []) do
    limit = clamp_limit(Keyword.get(opts, :limit))

    Delivery
    |> where([d], d.endpoint_id == ^endpoint_id)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_delivery_limit)
  defp clamp_limit(_), do: @default_delivery_limit

  # Repo.delete(struct, stale_error_field: :id) turns a would-be
  # Ecto.StaleEntryError into a changeset error tagged `stale: true`.
  defp stale?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, error_opts}} -> Keyword.get(error_opts, :stale) == true
      _ -> false
    end)
  end

  defp stale?(_), do: false
end
