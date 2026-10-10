defmodule Barkpark.Content.ScheduledPublishes do
  @moduledoc """
  Publish a document's draft at a future time (task-8e88b5539acafdae, Studio
  J40: Sanity's "Schedule draft for publishing").

  ## Who the publish runs as (owner decision 2026-10-10)

  The publish runs AS the person who scheduled it, not as a system user:

    * the row stores the scheduling principal (a user, or an API token and the
      user it acts for);
    * at run time that principal is loaded again and must still be able to
      write the workspace (`Tenancy.Auth.authorize/3`, `:write`; a token must
      also still be live). If it cannot, the schedule ends `refused` and the
      draft stays a draft;
    * the publish goes through `Content.publish_document/4` with that
      principal's `CallerContext`, so the revision history names them
      (`actor_kind` / `actor_id`) and every publish gate applies exactly as if
      they had pressed Publish themselves.

  ## Lifecycle

  `scheduled` -> `published` | `cancelled` | `refused` | `failed`. At most one
  `scheduled` row per document. Each change is announced on the document's
  listen stream as a `schedule` or `unschedule` event on the draft; the publish
  itself is the ordinary `publish` event.

  The timer is an Oban job (`ScheduledPublishWorker`) set to `publish_at`. The
  row is the source of truth: the job re-reads it and does nothing unless it is
  still `scheduled`, so cancelling needs no job surgery.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, CallerContext, DraftId, ScheduledPublish, Scope}
  alias Barkpark.Content.Workers.ScheduledPublishWorker
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @doc """
  Schedule the draft of `doc_id` to publish at `publish_at` (an ISO 8601
  string or a `DateTime`, in the future).

  `opts` carries the request scope (`scope_opts/1`): `:caller_context`,
  `:workspace_id`, `:project_id`. `opts[:draft_rev]` pins the draft revision:
  the publish then happens only if the draft is still at that rev.
  """
  def schedule(type, doc_id, dataset, publish_at, opts)
      when is_binary(type) and is_binary(doc_id) and is_binary(dataset) do
    with {:ok, principal} <- scheduling_principal(Keyword.get(opts, :caller_context)),
         {:ok, at} <- future_time(publish_at),
         {:ok, draft} <- fetch_draft(doc_id, type, dataset, opts),
         :ok <- check_pin(draft, Keyword.get(opts, :draft_rev)) do
      attrs =
        Map.merge(principal, %{
          workspace_id: workspace_id(opts),
          project_id: Keyword.get(opts, :project_id),
          dataset: dataset,
          type: type,
          doc_id: DraftId.published_id(doc_id),
          publish_at: at,
          draft_rev: Keyword.get(opts, :draft_rev)
        })

      Repo.transaction(fn ->
        with {:ok, row} <- Repo.insert(ScheduledPublish.create_changeset(attrs)),
             {:ok, _job} <-
               Oban.insert(ScheduledPublishWorker.new(%{id: row.id}, scheduled_at: at)) do
          row
        else
          {:error, %Ecto.Changeset{} = cs} ->
            if Keyword.has_key?(cs.errors, :workspace_id),
              do: Repo.rollback(:schedule_exists),
              else: Repo.rollback(cs)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> tap_announce(draft, "schedule")
    end
  end

  def schedule(_type, _doc_id, _dataset, _publish_at, _opts),
    do: {:error, {:schedule_invalid, "type and id are required"}}

  @doc """
  The schedules visible in this request's workspace (and project, when the URL
  names one) for `dataset`, soonest first. Filters: `"id"` (a document id,
  draft or published spelling), `"type"`, and `"status"` (default
  `"scheduled"`; `"all"` for every status).
  """
  def list(dataset, filters, opts) when is_binary(dataset) and is_map(filters) do
    ScheduledPublish
    |> Scope.scope_to_workspace(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    |> where([s], s.dataset == ^dataset)
    |> filter_doc(filters["id"])
    |> filter_type(filters["type"])
    |> filter_status(Map.get(filters, "status", "scheduled"))
    |> order_by([s], asc: s.publish_at, asc: s.inserted_at)
    |> limit(500)
    |> Repo.all()
  end

  @doc """
  Cancel a pending schedule. Only a `scheduled` row can be cancelled; any
  other status answers `{:error, {:schedule_not_pending, status}}`.
  """
  def cancel(id, dataset, opts) when is_binary(id) and is_binary(dataset) do
    with {:ok, row} <- fetch(id, dataset, opts),
         :ok <- pending(row),
         {:ok, row} <- Repo.update(ScheduledPublish.finish_changeset(row, "cancelled", nil)) do
      announce_for(row, "unschedule")
      {:ok, row}
    end
  end

  @doc """
  Run one schedule (called by `ScheduledPublishWorker` at `publish_at`).
  Returns the finished row, or `{:ok, :skipped}` when it is no longer pending.
  """
  def run(id) when is_binary(id) do
    case Repo.get(ScheduledPublish, id) do
      %ScheduledPublish{status: "scheduled"} = row -> execute(row)
      _ -> {:ok, :skipped}
    end
  end

  defp execute(row) do
    case acting_context(row) do
      {:ok, ctx} ->
        opts = [
          source: :schedule,
          user_id: row.acting_user_id,
          caller_context: ctx,
          workspace_id: read_scope(row),
          project_id: row.project_id
        ]

        with {:ok, draft} <- fetch_draft(row.doc_id, row.type, row.dataset, opts),
             :ok <- check_pin(draft, row.draft_rev),
             {:ok, _published} <-
               Content.publish_document(row.doc_id, row.type, row.dataset, opts) do
          finish(row, "published", nil)
        else
          {:error, :publish_not_permitted} ->
            finish(row, "refused", "the scheduler's seat cannot publish")

          {:error, reason} ->
            finish(row, "failed", failure_reason(reason))
        end

      {:refused, why} ->
        finish(row, "refused", why)
    end
  end

  defp finish(row, status, reason) do
    {:ok, row} = Repo.update(ScheduledPublish.finish_changeset(row, status, reason))
    if status != "published", do: announce_for(row, "unschedule")
    {:ok, row}
  end

  # ── Who schedules, and who runs ────────────────────────────────────────────

  defp scheduling_principal(%CallerContext{principal_type: :user, user_id: uid})
       when is_binary(uid),
       do: {:ok, %{principal_type: "user", principal_id: uid, acting_user_id: uid}}

  defp scheduling_principal(%CallerContext{principal_type: :api_token, token_id: tid} = ctx)
       when is_binary(tid),
       do: {:ok, %{principal_type: "api_token", principal_id: tid, acting_user_id: ctx.user_id}}

  # A share-edit visitor or an anonymous caller has no identity to run as.
  defp scheduling_principal(_ctx), do: {:error, :forbidden}

  # The scheduler, loaded fresh, as a CallerContext. Every refusal names what
  # changed, and the draft is left alone. The rows are read here without the
  # account and token modules (content stays below auth in the module graph);
  # the decision itself is `Tenancy.Auth.authorize/3` on the context, the same
  # seat rule a live request gets.
  defp acting_context(%ScheduledPublish{principal_type: "user"} = row) do
    if user_exists?(row.principal_id) do
      ctx =
        CallerContext.from_user(row.principal_id,
          roles: List.wrap(user_role(row.principal_id, row.workspace_id)),
          load_grants: false
        )

      with :ok <- may_write(ctx, row.workspace_id), do: {:ok, ctx}
    else
      {:refused, "the person who scheduled it no longer exists"}
    end
  end

  defp acting_context(%ScheduledPublish{principal_type: "api_token"} = row) do
    case live_token(row.principal_id) do
      %{} = token ->
        ctx = CallerContext.from_token(token, workspace_id: row.workspace_id)
        with :ok <- may_write(ctx, row.workspace_id), do: {:ok, ctx}

      nil ->
        {:refused, "the token that scheduled it is revoked or expired"}
    end
  end

  defp may_write(ctx, workspace_id) when is_binary(workspace_id) do
    case TenancyAuth.authorize(ctx, workspace_id, :write) do
      :ok -> :ok
      {:error, _} -> {:refused, "the scheduler no longer has write access to this workspace"}
    end
  end

  # A shared-layer document (no workspace): a token still needs write
  # permission; a user has no seat to lose there.
  defp may_write(%CallerContext{principal_type: :api_token, roles: perms}, nil) do
    if Enum.any?(~w(write admin), &(&1 in perms)),
      do: :ok,
      else: {:refused, "the scheduler no longer has write access"}
  end

  defp may_write(_ctx, nil), do: :ok

  defp user_exists?(user_id),
    do: Repo.exists?(from u in "users", where: u.id == type(^user_id, :binary_id))

  defp user_role(user_id, workspace_id) when is_binary(workspace_id),
    do: TenancyAuth.membership_role(user_id, workspace_id, :user)

  defp user_role(_user_id, _workspace_id), do: nil

  # The same liveness predicate as `Barkpark.Auth.token_live?/1`: an `api`
  # key, not revoked, not expired.
  defp live_token(token_id) do
    now = DateTime.utc_now()

    Repo.one(
      from t in "api_tokens",
        where:
          t.id == type(^token_id, :binary_id) and t.kind == "api" and is_nil(t.revoked_at) and
            (is_nil(t.expires_at) or t.expires_at > ^now),
        select: %{
          id: type(t.id, :binary_id),
          permissions: t.permissions,
          owner_user_id: type(t.owner_user_id, :binary_id)
        }
    )
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  defp future_time(%DateTime{} = at) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt,
      do: {:ok, at},
      else: {:error, {:schedule_invalid, "publishAt must be in the future"}}
  end

  defp future_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> future_time(at)
      _ -> {:error, {:schedule_invalid, "publishAt must be an ISO 8601 date-time with a zone"}}
    end
  end

  defp future_time(_),
    do: {:error, {:schedule_invalid, "publishAt is required (ISO 8601 date-time)"}}

  defp fetch_draft(doc_id, type, dataset, opts) do
    case Content.get_document(DraftId.draft_id(doc_id), type, dataset, opts) do
      {:ok, draft} -> {:ok, draft}
      _ -> {:error, {:not_found, "no draft to publish for #{DraftId.published_id(doc_id)}"}}
    end
  end

  defp check_pin(_draft, nil), do: :ok
  defp check_pin(%{rev: rev}, rev), do: :ok

  defp check_pin(%{rev: actual}, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: actual}}}

  defp fetch(id, dataset, opts) do
    with uuid when is_binary(uuid) <- Repo.uuid_or_nil(id),
         [row] <-
           ScheduledPublish
           |> Scope.scope_to_workspace(
             Keyword.get(opts, :workspace_id),
             Keyword.get(opts, :project_id)
           )
           |> where([s], s.id == ^uuid and s.dataset == ^dataset)
           |> Repo.all() do
      {:ok, row}
    else
      _ -> {:error, {:not_found, "schedule not found"}}
    end
  end

  defp pending(%ScheduledPublish{status: "scheduled"}), do: :ok
  defp pending(%ScheduledPublish{status: status}), do: {:error, {:schedule_not_pending, status}}

  defp workspace_id(opts) do
    case Keyword.get(opts, :workspace_id) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp filter_doc(query, id) when is_binary(id) and id != "",
    do: where(query, [s], s.doc_id == ^DraftId.published_id(id))

  defp filter_doc(query, _), do: query

  defp filter_type(query, type) when is_binary(type) and type != "",
    do: where(query, [s], s.type == ^type)

  defp filter_type(query, _), do: query

  defp filter_status(query, "all"), do: query

  defp filter_status(query, status) when is_binary(status),
    do: where(query, [s], s.status == ^status)

  defp filter_status(query, _), do: query

  defp failure_reason({:not_found, message}) when is_binary(message), do: message
  defp failure_reason({:rev_mismatch, _}), do: "the draft changed after it was scheduled"
  defp failure_reason(reason), do: reason |> inspect() |> String.slice(0, 200)

  # A schedule with no workspace belongs to the shared layer; read it there and
  # never across tenants (`nil` would mean "every workspace" to the readers).
  defp read_scope(%ScheduledPublish{workspace_id: nil}), do: :shared_only
  defp read_scope(%ScheduledPublish{workspace_id: ws}), do: ws

  # ── Listen events ──────────────────────────────────────────────────────────

  defp tap_announce({:ok, row}, draft, kind) do
    announce(draft, kind)
    {:ok, row}
  end

  defp tap_announce(error, _draft, _kind), do: error

  # The event rides the document's draft (or, once published, the published
  # row) so a listener filtered to that document sees it.
  defp announce_for(row, kind) do
    opts = [workspace_id: read_scope(row), project_id: row.project_id]

    [DraftId.draft_id(row.doc_id), row.doc_id]
    |> Enum.find_value(fn id ->
      case Content.get_document(id, row.type, row.dataset, opts) do
        {:ok, doc} -> doc
        _ -> nil
      end
    end)
    |> case do
      nil -> :ok
      doc -> announce(doc, kind)
    end
  end

  defp announce(doc, kind) do
    event = Broadcast.save_event(doc, doc.type, doc.dataset, kind, doc.rev, :schedule)
    Broadcast.broadcast_document_mutation(doc, kind, event_id: event.id, previous_rev: doc.rev)
  end
end
