defmodule Barkpark.Webhooks do
  import Ecto.Query
  require Logger
  alias Barkpark.Audit
  alias Barkpark.Repo
  alias Barkpark.Content.Scope
  alias Barkpark.Webhooks.{Webhook, Delivery}

  # ── Half-open recovery for the auto-disable latch ────────────────────────
  #
  # An auto-disabled endpoint is NOT dead: after a cooldown it rejoins the
  # delivery candidate set for ONE probe. Entry and exit are both automatic, so
  # a receiver outage that outlives an operator's attention cannot permanently
  # end a tenant's webhook delivery. Mirrors `Barkpark.Audit.Export`, which
  # already runs this exact shape for SIEM export sinks.
  #
  # The cooldown grows with how far the streak has run PAST the latch
  # threshold — i.e. with how many probes have already failed — so a receiver
  # that is down for a week is probed ~24x/day, not on every content change.
  # A failed probe pushes `auto_disabled_at` forward (`restart_cooldown/3`);
  # without that the stamp stays old, every subsequent event is "due", and the
  # probe degenerates into the retry storm the latch exists to prevent.
  @retry_base_seconds 60
  @retry_max_seconds 3600
  # Bounds the exponent so `2 ** over` cannot build a giant integer on an
  # endpoint whose streak ran into the thousands.
  @retry_max_doublings 8

  # Stable, greppable log codes for the latch transitions — the operator-facing
  # half. `webhook_endpoint_auto_disabled` says a tenant's integration went
  # dark; `webhook_endpoint_recovered` closes the incident.
  @disabled_code "webhook_endpoint_auto_disabled"
  @recovered_code "webhook_endpoint_recovered"
  @probe_failed_code "webhook_endpoint_probe_failed"

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
    |> audit_webhook("webhook_created")
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
    |> maybe_apply_reenable(webhook)
    |> Repo.update()
    |> audit_webhook("webhook_updated")
  end

  # When an update transitions `active` false→true, fold FULL re-enable
  # semantics into the SAME write: zero the consecutive-failure streak and clear
  # the `auto_disabled_at` / `disable_reason` stamps (mirrors reenable_webhook/1),
  # merged with the caller's other field updates. Without this, a PUT {active:true}
  # on an auto-disabled hook would leave the stale kill-streak + disable_reason in
  # place, so the very next single terminal give-up re-crosses the threshold and
  # re-disables it. `active` / `consecutive_failures` / the stamps are server-
  # managed (not client-castable except `active`), so this is the sole caller-
  # facing re-enable path — every caller of update_webhook/2 inherits it.
  # Already-active hooks produce no `:active` change, so this is a no-op for them
  # (idempotent); manual disable (active true→false) never enters this branch and
  # therefore never fabricates a disable_reason.
  defp maybe_apply_reenable(%Ecto.Changeset{} = changeset, %Webhook{active: false}) do
    if Ecto.Changeset.get_change(changeset, :active) == true do
      Ecto.Changeset.change(changeset,
        consecutive_failures: 0,
        auto_disabled_at: nil,
        disable_reason: nil
      )
    else
      changeset
    end
  end

  defp maybe_apply_reenable(%Ecto.Changeset{} = changeset, %Webhook{}), do: changeset

  def delete_webhook(%Webhook{} = webhook) do
    # A concurrent double-DELETE would raise Ecto.StaleEntryError (→ 500).
    # stale_error_field turns the race into {:error, :not_found} (rendered 404).
    case Repo.delete(webhook, stale_error_field: :id) do
      {:error, cs} -> if stale?(cs), do: {:error, :not_found}, else: {:error, cs}
      ok -> audit_webhook(ok, "webhook_deleted")
    end
  end

  # A webhook is an event-exfiltration surface (it forwards content + audit
  # events off-box to an arbitrary URL and holds a signing secret), so every
  # CRUD transition lands on the tamper-evident audit trail. Category
  # `plugin_settings` (an EXISTING audit category, and already in the webhook
  # subscription mirror) is the honest bucket — a webhook is a delivery-config
  # surface, not a session/token credential. Chains into the row's OWN
  # per-workspace hash chain via `workspace_id`, so a cross-tenant admin never
  # sees another tenant's webhook events. Best-effort + isolated: the emit
  # result is discarded and any infra raise/throw is swallowed, so an audit
  # hiccup can never fail the CRUD that already committed. Field hygiene: the
  # signing `secret` is NEVER put in metadata.
  defp audit_webhook({:ok, %Webhook{} = webhook} = result, action) do
    Audit.emit(%{
      category: "plugin_settings",
      action: action,
      subject: webhook.id,
      workspace_id: webhook.workspace_id,
      project_id: webhook.project_id,
      metadata: %{"name" => webhook.name, "dataset" => webhook.dataset}
    })

    result
  rescue
    _ -> result
  catch
    _, _ -> result
  end

  defp audit_webhook(result, _action), do: result

  @doc """
  Select the DELIVERABLE webhooks that fire for an event, optionally scoped to a
  workspace/project. Deliverable means every active endpoint, PLUS every
  AUTO-disabled endpoint whose backoff cooldown has elapsed — one half-open
  probe, so a recovered receiver resumes without a human. An endpoint a PERSON
  disabled is never included (see `deliverable/2`).

  `opts` may carry `:workspace_id` / `:project_id` (threaded from the changed
  doc's scope). When present, the selection is filtered through
  `Content.Scope.scope_to_workspace/3` so a content change in workspace B never
  selects workspace A's webhooks — the cross-tenant delivery leak guard. The
  dataset + events + types filters are unchanged; this ADDS the workspace
  envelope around them. A `nil`/absent `workspace_id` keeps the pre-tenancy
  unscoped behaviour (matches every webhook in the dataset).
  """
  def active_webhooks_for(dataset, event, type, opts \\ []) do
    now = DateTime.utc_now()

    Webhook
    |> where([w], w.dataset == ^dataset)
    |> deliverable(now)
    # A webhook with audit_categories set is an AUDIT subscriber, not a content
    # one — exclude it from content fan-out so the two channels never cross.
    |> where([w], fragment("? = '{}'", w.audit_categories))
    # A webhook with a blocked_threshold_s is a CHAT_BLOCKED subscriber (herd
    # layer, D59h) — exclude it too, else a chat_blocked row with the default
    # empty events/types would match every content event and cross channels.
    |> where([w], is_nil(w.blocked_threshold_s))
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.events, w.events, ^event))
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.types, w.types, ^type))
    |> scope(opts)
    |> Repo.all()
    |> Enum.filter(&probe_due?(&1, now))
  end

  @doc """
  Active AUDIT-event subscriptions matching an emitted event (era-w7): a
  non-empty `audit_categories` that CONTAINS the event's category, and (if
  `audit_actions` is set) that CONTAINS the action. Org scope: a subscription
  with `organization_id` only matches events attributed to that org (via the
  event's `metadata["organization_id"]` or a workspace under it); a global
  (nil-org) subscription sees everything — admin-only by construction.
  """
  def audit_webhooks_for(category, action, org_id) when is_binary(category) do
    now = DateTime.utc_now()

    Webhook
    |> deliverable(now)
    |> where([w], fragment("? <> '{}'", w.audit_categories))
    |> where([w], fragment("? @> ARRAY[?]::varchar[]", w.audit_categories, ^category))
    |> where(
      [w],
      fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.audit_actions, w.audit_actions, ^action)
    )
    |> audit_org_scope(org_id)
    |> Repo.all()
    |> Enum.filter(&probe_due?(&1, now))
  end

  # ── Half-open probe admission ────────────────────────────────────────────

  # SQL prefilter: every active endpoint, PLUS every AUTO-disabled endpoint
  # whose SHORTEST possible cooldown has elapsed. The exact per-row cooldown
  # depends on that row's streak, so it is refined in Elixir by `probe_due?/2`
  # over the (small) disabled set rather than encoded as a SQL expression.
  #
  # An endpoint a PERSON disabled (`active: false` with NO `auto_disabled_at`
  # stamp) is never admitted: only the automatic latch gets an automatic exit.
  # This is the load-bearing half of the guard — without the `auto_disabled_at`
  # test, a probe would resurrect an endpoint an operator deliberately turned
  # off.
  defp deliverable(query, now) do
    earliest = DateTime.add(now, -@retry_base_seconds, :second)

    where(
      query,
      [w],
      w.active == true or
        (not is_nil(w.auto_disabled_at) and w.auto_disabled_at <= ^earliest)
    )
  end

  @doc """
  When this endpoint's next half-open probe becomes due — `nil` for an endpoint
  that is active, or one a person disabled by hand (never probed).
  """
  def next_probe_at(%Webhook{active: true}), do: nil
  def next_probe_at(%Webhook{auto_disabled_at: nil}), do: nil

  def next_probe_at(%Webhook{} = w),
    do: DateTime.add(w.auto_disabled_at, cooldown_seconds(w.consecutive_failures), :second)

  defp probe_due?(%Webhook{active: true}, _now), do: true
  defp probe_due?(%Webhook{auto_disabled_at: nil}, _now), do: false

  defp probe_due?(%Webhook{} = w, now),
    do: DateTime.compare(next_probe_at(w), now) != :gt

  # 60s, 120s, 240s ... capped at @retry_max_seconds, keyed off how far the
  # streak has run PAST the latch threshold (i.e. how many probes have failed).
  defp cooldown_seconds(failures) do
    doublings =
      failures |> Kernel.-(auto_disable_threshold()) |> max(0) |> min(@retry_max_doublings)

    min(@retry_base_seconds * Integer.pow(2, doublings), @retry_max_seconds)
  end

  # A subscription scoped to an org only fires for that org's events; a global
  # subscription (nil organization_id) fires for all. When the event carries no
  # org, only global subscriptions match.
  defp audit_org_scope(query, nil),
    do: where(query, [w], is_nil(w.organization_id))

  defp audit_org_scope(query, org_id),
    do: where(query, [w], is_nil(w.organization_id) or w.organization_id == ^org_id)

  @doc """
  Active CHAT_BLOCKED subscriptions for a workspace (herd layer, charter D59h):
  a workspace-scoped `webhooks` row with a non-NULL `blocked_threshold_s` (the
  subscription flag AND the per-workspace debounce threshold in one column).

  WORKSPACE-scoped, never org-wide — deliberately UNLIKE `audit_webhooks_for/3`,
  whose org-only semantics are untouched. A `nil` `workspace_id` never matches
  (`w.workspace_id == ^nil` is a forbidden Ecto comparison AND fail-closed by
  intent — a NULL-owner session must never notify, D43h), so the caller must not
  pass nil; `BlockedSweeper` only ever passes the concrete owner_workspace_id of
  a session that actually has a pending ask.
  """
  def chat_blocked_webhooks_for(workspace_id) when is_binary(workspace_id) do
    Webhook
    |> where([w], w.active == true)
    |> where([w], w.workspace_id == ^workspace_id)
    |> where([w], not is_nil(w.blocked_threshold_s))
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
  Claim a CHAT_BLOCKED delivery slot for `(endpoint_id, dedupe_key)` (herd
  layer, charter D57h). Returns `{:ok, delivery}` on the first claim, or
  `{:error, :already_delivered}` if a chat_blocked row already exists for this
  pair. The `dedupe_key` is the pending ask's `chat_messages` id stringified, so
  a re-sweep of the SAME still-blocked ask claims the same slot and no-ops —
  exactly-once per ask. `event_id` stays NULL; the exactly-once axis is the
  partial UNIQUE(endpoint_id, dedupe_key) WHERE source_kind='chat_blocked', which
  Ecto infers via the `:unsafe_fragment` conflict target (a plain column list
  cannot express the partial predicate). `payload_snapshot` carries the encoded
  body so a crash-recovery retry rebuilds without a `mutation_events` source.
  """
  def claim_chat_blocked_delivery(endpoint_id, dedupe_key, payload_snapshot)
      when is_binary(dedupe_key) and is_map(payload_snapshot) do
    case Repo.insert(
           Delivery.changeset(%Delivery{}, %{
             source_kind: "chat_blocked",
             endpoint_id: endpoint_id,
             dedupe_key: dedupe_key,
             status: "pending",
             attempts: 0,
             payload_snapshot: payload_snapshot
           }),
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(endpoint_id, dedupe_key) WHERE source_kind = 'chat_blocked'"}
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

  @doc """
  Insert a durable AUDIT delivery row (`source_kind: "audit"`) for `endpoint_id`
  (era-w7). Like media: no content `event_id` FK, never deduped, but it targets
  a real webhook so retries + dead-letter attribute to it.
  """
  def create_audit_delivery(endpoint_id, payload_snapshot) when is_map(payload_snapshot) do
    %Delivery{}
    |> Delivery.changeset(%{
      source_kind: "audit",
      endpoint_id: endpoint_id,
      status: "pending",
      attempts: 0,
      payload_snapshot: payload_snapshot
    })
    |> Repo.insert()
  end

  @doc """
  Insert a durable TEST delivery row (`source_kind: "test"`, GR45) for a one-shot
  admin PROBE (`POST /v1/webhooks/:dataset/:id/test-send`).

  Mirrors `create_media_delivery/1` deliberately: `endpoint_id` and `event_id`
  stay NULL, so the row carries only the synthetic body in `payload_snapshot`.
  A NULL `endpoint_id` is the crux of the safety contract — `mark_delivered/4`
  and `mark_giveup/5` no-op their streak accounting on a nil endpoint, so a test
  send (success OR failure) never resets a healthy endpoint's history nor pushes
  a flaky one toward auto-disable. The probe is single-attempt (see
  `Dispatcher.deliver_test/3`) and never resumed, so no `endpoint_id` is needed
  for a retry to re-target.
  """
  def create_test_delivery(payload_snapshot) when is_map(payload_snapshot) do
    %Delivery{}
    |> Delivery.changeset(%{
      source_kind: "test",
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

  Also the AUTOMATIC exit from the auto-disable latch: if the successful
  delivery was a half-open probe against an auto-disabled endpoint, the endpoint
  is re-enabled here and the recovery is announced. A recovered receiver
  therefore resumes with no human action.
  """
  # A media delivery (`source_kind: "media"`) carries no `endpoint_id` — its
  # endpoints are config-driven, not `webhooks` rows — so there is no
  # consecutive-failure streak to reset (and `w.id == ^nil` is a forbidden Ecto
  # comparison). No-op for those.
  def reset_endpoint_failures(nil), do: {0, nil}

  def reset_endpoint_failures(endpoint_id) do
    recover_endpoint(endpoint_id)

    from(w in Webhook, where: w.id == ^endpoint_id and w.consecutive_failures > 0)
    |> Repo.update_all(set: [consecutive_failures: 0])
  end

  # The half-open probe SUCCEEDED: close the latch automatically. Guarded on
  # `active == false AND auto_disabled_at IS NOT NULL`, so it only ever
  # resurrects an endpoint the AUTOMATIC latch disabled — an endpoint a person
  # switched off carries no `auto_disabled_at` stamp and is untouched here (it
  # is also never selected for delivery, so it cannot reach this path at all;
  # the guard is belt-and-braces against a future caller).
  #
  # Emits the recovery signal exactly once per dark interval: the `active ==
  # false` guard means the SECOND success in a row updates zero rows.
  defp recover_endpoint(endpoint_id) do
    was_dark_since =
      Repo.one(from(w in Webhook, where: w.id == ^endpoint_id, select: w.auto_disabled_at))

    {n, rows} =
      from(w in Webhook,
        where: w.id == ^endpoint_id and w.active == false and not is_nil(w.auto_disabled_at),
        select: w
      )
      |> Repo.update_all(
        set: [
          active: true,
          consecutive_failures: 0,
          auto_disabled_at: nil,
          disable_reason: nil,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

    # `UPDATE ... RETURNING` hands back the POST-update row, whose
    # `auto_disabled_at` this write just cleared — so "how long was it dark" has
    # to come from the stamp read BEFORE the flip. The read is unguarded and the
    # write is guarded, so a concurrent recovery costs at worst a `nil` here,
    # never a wrong flip.
    now = DateTime.utc_now()

    if n > 0 do
      Enum.each(rows || [], &signal_recovered(&1, dark_seconds(was_dark_since, now)))
    end

    {n, rows}
  end

  # Logged at WARNING, matching the disable line rather than demoting the close
  # to info: an operator alerting on the disable code needs the SAME channel to
  # tell them the incident ended, or every dark interval stays open forever in
  # their alerting.
  defp dark_seconds(nil, _now), do: nil
  defp dark_seconds(since, now), do: DateTime.diff(now, since, :second)

  defp signal_recovered(%Webhook{} = w, dark_for_seconds) do
    Logger.warning(
      "[#{@recovered_code}] webhook endpoint #{w.id} (#{w.name}, dataset #{w.dataset}) " <>
        "recovered after #{dark_for_seconds}s disabled: a half-open probe delivered " <>
        "successfully; deliveries resume"
    )

    emit_latch_event(w, "webhook_auto_reenabled", %{"dark_for_seconds" => dark_for_seconds})
  end

  @doc """
  Record a TRUE terminal give-up against an endpoint: atomically increment its
  `consecutive_failures`, and auto-disable it once the streak crosses the
  configured threshold. The increment uses a single `UPDATE ... RETURNING` so
  concurrent deliveries can't lose a count, and the auto-disable write is gated
  on `active == true` so it stamps `auto_disabled_at` / `disable_reason` exactly
  once. A later give-up on an ALREADY-disabled row is a failed half-open probe:
  it re-stamps `auto_disabled_at` so the next probe waits out a longer cooldown,
  and it does NOT re-announce the latch (one signal per dark interval).
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

    {n, rows} =
      from(w in Webhook, where: w.id == ^endpoint_id and w.active == true, select: w)
      |> Repo.update_all(
        set: [
          active: false,
          auto_disabled_at: now,
          disable_reason: disable_reason,
          updated_at: now
        ]
      )

    # The `active == true` guard is what makes the SIGNAL fire exactly once at
    # the threshold crossing rather than on every subsequent give-up: only the
    # first give-up past the threshold updates a row, so only it has a row to
    # announce.
    if n > 0 do
      Enum.each(rows || [], &signal_auto_disabled(&1, count, disable_reason))
    else
      # Zero rows means the endpoint was ALREADY auto-disabled and this failure
      # is a half-open probe that failed again. Push the cooldown forward so the
      # NEXT probe waits longer — without this the `auto_disabled_at` stamp
      # stays old, every subsequent event is "due", and the probe becomes a
      # retry storm against a receiver that is already known to be down.
      restart_cooldown(endpoint_id, count, disable_reason, now)
    end

    {n, rows}
  end

  # The operator-facing half of the latch. Before this, an endpoint went dark
  # and the ONLY witness was a `disable_reason` column nobody was looking at:
  # a tenant's cache revalidation and downstream syncs stopped with no log
  # line, no audit row, and no notification. Two signals, deliberately:
  #
  #   * a greppable WARNING carrying `@disabled_code`, for log-based alerting;
  #   * an AUDIT event on the endpoint's own per-workspace hash chain, so the
  #     stop is a durable, tamper-evident RECORD an operator can query later —
  #     not just a line that ages out of a log buffer.
  defp signal_auto_disabled(%Webhook{} = w, count, disable_reason) do
    Logger.warning(
      "[#{@disabled_code}] webhook endpoint #{w.id} (#{w.name}, dataset #{w.dataset}) " <>
        "auto-disabled after #{count} consecutive terminal give-ups. Deliveries are " <>
        "STOPPED. A half-open probe retries in #{cooldown_seconds(count)}s; " <>
        "POST /v1/webhooks/#{w.dataset}/#{w.id}/reenable resumes immediately."
    )

    emit_latch_event(w, "webhook_auto_disabled", %{
      "consecutive_failures" => count,
      "disable_reason" => disable_reason,
      "next_probe_in_seconds" => cooldown_seconds(count)
    })
  end

  # A half-open probe failed again: re-stamp `auto_disabled_at` so the backoff
  # keys off NOW. Logged at info (not warning) and NOT audited — the incident
  # was already announced by `signal_auto_disabled/3`; one line per dark
  # interval is the signal, a line per probe is noise.
  defp restart_cooldown(endpoint_id, count, disable_reason, now) do
    from(w in Webhook,
      where: w.id == ^endpoint_id and w.active == false and not is_nil(w.auto_disabled_at)
    )
    |> Repo.update_all(
      set: [auto_disabled_at: now, disable_reason: disable_reason, updated_at: now]
    )

    Logger.info(
      "[#{@probe_failed_code}] webhook endpoint #{endpoint_id} probe failed; " <>
        "next retry in #{cooldown_seconds(count)}s"
    )
  end

  # Same chaining + hygiene contract as `audit_webhook/2`: the endpoint's own
  # `workspace_id` chain, no signing secret in metadata, and fully isolated —
  # an audit hiccup must never turn a delivery give-up into a crash.
  #
  # `Audit.emit/1` bridges to audit-event webhook subscriptions, which can
  # themselves fail and count toward a streak. That cannot recurse: this emit
  # only happens on a THRESHOLD CROSSING, and the `active == true` guard above
  # makes a crossing a once-per-dark-interval event.
  defp emit_latch_event(%Webhook{} = w, action, extra) do
    Audit.emit(%{
      category: "plugin_settings",
      action: action,
      subject: w.id,
      workspace_id: w.workspace_id,
      project_id: w.project_id,
      metadata: Map.merge(%{"name" => w.name, "dataset" => w.dataset}, extra)
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Human-readable disable reason, bounded so a long transport error can't
  # overflow the `disable_reason` string column.
  defp build_disable_reason(count, reason) do
    detail = reason |> to_string() |> String.slice(0, 180)
    "auto-disabled after #{count} consecutive delivery failures (last: #{detail})"
  end

  @doc """
  Re-enable an auto-disabled (or manually disabled) endpoint directly. Fully
  restores the endpoint to a clean deliverable state: `active: true`,
  `consecutive_failures: 0`, and clears the `auto_disabled_at` /
  `disable_reason` stamps. Idempotent for an already-active endpoint (writes it
  back to the same clean state — unlike the `update_webhook/2` fold, this also
  clears an in-progress streak on an active endpoint).

  The HTTP-facing path (console toggle / PUT `{active: true}`) does NOT call
  this — it rides `update_webhook/2`, whose false→true fold applies the same
  semantics merged with the caller's other field updates in one write.
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
