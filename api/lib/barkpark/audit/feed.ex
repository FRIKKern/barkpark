defmodule Barkpark.Audit.Feed do
  @moduledoc """
  The one read of the audit log a workspace admin gets: the HTTP route
  (`BarkparkWeb.AuditController`, `bp audit ls`) and the Studio Activity page
  (`BarkparkWeb.Studio.AuditLive`) both call `list/3`. There is no second path.

  ## Which rows

  Rows whose `workspace_id` is the given workspace, and whose `project_id` is
  the given project or NULL (workspace-level rows such as token mints, access
  grants and seat changes). A row of a sibling project in the same workspace
  does not show, and neither does a row with no workspace (instance-level
  rows: sign-ins, MFA, SSO, SCIM and organization changes all write with a
  NULL workspace). Without a valid workspace and project id the answer is
  empty, never unscoped.

  ## Which fields

  A row's `metadata` is never returned. Its writers put token labels (which
  can hold an email), raw emails (`bootstrap_owner_created`), receiver error
  text with IP addresses (`webhook_auto_disabled`), a token file path and a
  host name (`admin_token_recovery_mint`) and lists of token ids there. Each
  row carries only:

    * `at`, `category`, `action`
    * `actor_type`, `actor_id` (a user or token id, or a fixed system label),
      and `actor_name`, the person's display name, only when that user holds a
      seat in this workspace (the member list shows admins the same name)
    * `target_type` (derived from category and action) and `target_id` (the
      row's `subject`, an id); an actor or target id holding "@" is dropped
    * `dataset` and `doc_type`: `metadata.dataset` and, for content changes,
      `metadata.type`, only when each is a plain slug
    * `project_wide`: true for a row with no project

  ## Filters and paging

  `parse/1` reads string params: `category` (one of `Event.categories/0`),
  `actor` (an exact actor id), `since` and `until` (an ISO 8601 date or time; an
  `until` date includes that whole day), `limit` (default 50, capped at 200).
  Every filter narrows the scoped query; none can widen it. Paging is by
  keyset: `:before_id` lists rows older than that id. The HTTP route hands
  callers an encrypted cursor bound to the workspace and project, so the raw
  id, a global sequence, is never shown.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Accounts
  alias Barkpark.Audit.Event
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Membership

  @default_limit 50
  @max_limit 200
  @max_actor 200
  @slug ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @type filters :: %{
          optional(:category) => String.t(),
          optional(:actor) => String.t(),
          optional(:from) => DateTime.t(),
          optional(:to) => {:before | :until, DateTime.t()},
          optional(:before_id) => pos_integer(),
          limit: pos_integer()
        }

  @type row :: %{
          at: DateTime.t(),
          category: String.t(),
          action: String.t(),
          actor_type: String.t() | nil,
          actor_id: String.t() | nil,
          actor_name: String.t() | nil,
          target_type: String.t() | nil,
          target_id: String.t() | nil,
          dataset: String.t() | nil,
          doc_type: String.t() | nil,
          project_wide: boolean()
        }

  @doc "The largest page `list/3` returns."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Read filters from string params. Blank values count as absent. Returns
  `{:error, {:invalid, field}}` naming the first field it cannot read.
  """
  @spec parse(map()) :: {:ok, filters()} | {:error, {:invalid, String.t()}}
  def parse(params) when is_map(params) do
    with {:ok, acc} <- put_category(present(params["category"]), %{}),
         {:ok, acc} <- put_actor(present(params["actor"]), acc),
         {:ok, acc} <- put_from(present(params["since"]), acc),
         {:ok, acc} <- put_to(present(params["until"]), acc) do
      put_limit(present(params["limit"]), acc)
    end
  end

  def parse(_params), do: {:ok, %{limit: @default_limit}}

  @doc """
  One page of the workspace's audit rows, newest first. `next_before_id` is
  the id to pass as `:before_id` for the next page, or nil on the last page.
  """
  @spec list(String.t() | nil, String.t() | nil, filters()) :: %{
          events: [row()],
          next_before_id: pos_integer() | nil,
          limit: pos_integer()
        }
  def list(workspace_id, project_id, filters) do
    limit = filters |> Map.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    with {:ok, ws} <- Ecto.UUID.cast(workspace_id),
         {:ok, proj} <- Ecto.UUID.cast(project_id) do
      events =
        from(e in Event,
          where: e.workspace_id == type(^ws, Ecto.UUID),
          where: is_nil(e.project_id) or e.project_id == type(^proj, Ecto.UUID),
          order_by: [desc: e.id],
          limit: ^(limit + 1)
        )
        |> narrow(filters)
        |> Repo.all()

      {page, rest} = Enum.split(events, limit)
      next = if rest != [], do: List.last(page).id

      %{events: rows(page, ws), next_before_id: next, limit: limit}
    else
      _ -> %{events: [], next_before_id: nil, limit: limit}
    end
  end

  # ── filters ────────────────────────────────────────────────────────────

  defp narrow(query, filters) do
    Enum.reduce(filters, query, fn
      {:category, c}, q -> where(q, [e], e.category == ^c)
      {:actor, a}, q -> where(q, [e], e.actor_id == ^a)
      {:from, at}, q -> where(q, [e], e.occurred_at >= ^at)
      {:to, {:before, at}}, q -> where(q, [e], e.occurred_at < ^at)
      {:to, {:until, at}}, q -> where(q, [e], e.occurred_at <= ^at)
      {:before_id, id}, q -> where(q, [e], e.id < ^id)
      _other, q -> q
    end)
  end

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp present(_v), do: nil

  defp put_category(nil, acc), do: {:ok, acc}

  defp put_category(c, acc) do
    if c in Event.categories(),
      do: {:ok, Map.put(acc, :category, c)},
      else: {:error, {:invalid, "category"}}
  end

  defp put_actor(nil, acc), do: {:ok, acc}

  defp put_actor(a, acc) when byte_size(a) <= @max_actor do
    if String.valid?(a), do: {:ok, Map.put(acc, :actor, a)}, else: {:error, {:invalid, "actor"}}
  end

  defp put_actor(_a, _acc), do: {:error, {:invalid, "actor"}}

  defp put_from(nil, acc), do: {:ok, acc}

  defp put_from(v, acc) do
    case moment(v) do
      {:date, d} -> {:ok, Map.put(acc, :from, DateTime.new!(d, ~T[00:00:00], "Etc/UTC"))}
      {:time, t} -> {:ok, Map.put(acc, :from, t)}
      :error -> {:error, {:invalid, "since"}}
    end
  end

  defp put_to(nil, acc), do: {:ok, acc}

  defp put_to(v, acc) do
    case moment(v) do
      {:date, d} ->
        {:ok,
         Map.put(acc, :to, {:before, DateTime.new!(Date.add(d, 1), ~T[00:00:00], "Etc/UTC")})}

      {:time, t} ->
        {:ok, Map.put(acc, :to, {:until, t})}

      :error ->
        {:error, {:invalid, "until"}}
    end
  end

  defp moment(v) do
    with {:error, _} <- DateTime.from_iso8601(v),
         {:error, _} <- Date.from_iso8601(v) do
      :error
    else
      {:ok, %DateTime{} = t, _offset} -> {:time, t}
      {:ok, %Date{} = d} -> {:date, d}
    end
  end

  defp put_limit(nil, acc), do: {:ok, Map.put(acc, :limit, @default_limit)}

  defp put_limit(v, acc) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> {:ok, Map.put(acc, :limit, min(n, @max_limit))}
      _ -> {:error, {:invalid, "limit"}}
    end
  end

  # ── rows ───────────────────────────────────────────────────────────────

  defp rows(events, ws) do
    names = seated_names(events, ws)
    Enum.map(events, &row(&1, names))
  end

  defp row(%Event{} = e, names) do
    %{
      at: e.occurred_at,
      category: e.category,
      action: e.action,
      actor_type: e.actor_type,
      actor_id: plain(e.actor_id),
      actor_name: if(e.actor_type == "user", do: Map.get(names, e.actor_id)),
      target_type: target_type(e.category, e.action),
      target_id: plain(e.subject),
      dataset: slug(e.metadata, "dataset"),
      doc_type: if(e.category == "content_mutation", do: slug(e.metadata, "type")),
      project_wide: is_nil(e.project_id)
    }
  end

  # An id, never an email: a subject or actor id holding "@" is dropped.
  defp plain(v) when is_binary(v), do: if(String.contains?(v, "@"), do: nil, else: v)
  defp plain(_v), do: nil

  defp slug(%{} = metadata, key) do
    case Map.get(metadata, key) do
      v when is_binary(v) -> if Regex.match?(@slug, v), do: v
      _ -> nil
    end
  end

  defp slug(_metadata, _key), do: nil

  # Display names of the row actors who hold a user seat in THIS workspace.
  defp seated_names(events, ws) do
    ids =
      for %Event{actor_type: "user", actor_id: id} <- events,
          {:ok, uuid} <- [Ecto.UUID.cast(id)],
          uniq: true,
          do: uuid

    seated =
      if ids == [],
        do: [],
        else:
          Repo.all(
            from m in Membership,
              where:
                m.workspace_id == ^ws and m.principal_type == "user" and
                  m.principal_id in ^ids,
              select: m.principal_id
          )

    Accounts.display_names(seated)
  end

  defp target_type("content_mutation", "document." <> _), do: "document"
  defp target_type("content_mutation", "dataset_" <> _), do: "dataset"
  defp target_type("access", "grant." <> _), do: "grant"
  defp target_type("access", "workspace." <> _), do: "workspace"
  defp target_type("plugin_settings", "webhook_" <> _), do: "webhook"
  defp target_type("plugin_settings", "pull_provenance" <> _), do: "workspace"
  defp target_type("token", "user_tokens_revoked"), do: "user"
  defp target_type("token", _action), do: "token"
  defp target_type("membership", "scim_group_" <> _), do: "group"
  defp target_type("membership", _action), do: "user"
  defp target_type("secret", _action), do: "secret"
  defp target_type(_category, _action), do: nil
end
