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
  @scope_keys ["workspace_id", "project_id", "dataset_id", :workspace_id, :project_id, :dataset_id]

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

  def mark_delivered(%Delivery{} = d, status_code, attempts) do
    d
    |> Delivery.changeset(%{
      status: "ok",
      last_status_code: status_code,
      attempts: attempts
    })
    |> Repo.update()
  end

  def mark_giveup(%Delivery{} = d, status_code, reason, attempts) do
    d
    |> Delivery.changeset(%{
      status: "failed_giveup",
      last_status_code: status_code,
      last_error_text: reason,
      attempts: attempts
    })
    |> Repo.update()
  end

  def get_delivery(endpoint_id, event_id) do
    Delivery
    |> where([d], d.endpoint_id == ^endpoint_id and d.event_id == ^event_id)
    |> Repo.one()
  end

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
