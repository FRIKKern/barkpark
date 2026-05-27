defmodule BarkparkWeb.TasksController do
  @moduledoc """
  W7b step 1 (paperflow-rx0 / w7-07a) — HTTP surface for paperflow's
  bd-compatible shim (`bin/bd-shim`, paperflow side).

  Five endpoints, all bearer-token gated via the existing `:api` +
  `:require_token` pipelines in `router.ex`:

    * `GET    /v1/tasks/ready`              — `Tasks.ready/1`
    * `POST   /v1/tasks/claim`              — `Tasks.claim/2`
    * `POST   /v1/tasks/:doc_id/close`      — `Tasks.close/3`
    * `GET    /v1/tasks/:doc_id/edges`      — `Tasks.dependencies/2` + `dependents/2`
    * `POST   /v1/tasks/edges`              — `Tasks.add_dep/3`

  ## Shape contract

  All read responses carry a `doc` (or `docs`) map shaped to mirror what
  the real `bd show --json` emits closely enough that the shim can pass
  it through unchanged (`id`, `title`, `status`, `type`, `lifecycle_status`,
  `kind`, `content`, `priority`, `assignee`, `dependencies`, …). See
  `render_doc/1`. The shim translates label-flavoured bd args to query
  params upstream of this controller.

  ## Why the doc_id is a URL segment for close but a body field for claim

  Claim's contract is "pick the next ready row" — there is no specific row
  the caller is naming. Close's contract is "terminate THIS row I just held
  the claim on" — the caller names it. The route shapes mirror the verb.
  """

  use BarkparkWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Repo, Tasks}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Edge

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  # ─── GET /v1/tasks/ready ────────────────────────────────────────────────

  def ready(conn, params) do
    opts =
      []
      |> put_opt(:phase_id, params["phase_id"])
      |> put_opt(:limit, parse_int(params["limit"], nil))
      |> Keyword.merge(scope_opts(conn))

    docs = Tasks.ready(opts)
    json(conn, %{ok: true, docs: Enum.map(docs, &render_doc/1)})
  end

  # ─── POST /v1/tasks/claim ───────────────────────────────────────────────

  def claim(conn, params) do
    case params["worker_id"] do
      worker_id when is_binary(worker_id) and byte_size(worker_id) > 0 ->
        opts =
          []
          |> put_opt(:phase_id, params["phase_id"])
          |> Keyword.merge(scope_opts(conn))

        case Tasks.claim(worker_id, opts) do
          {:ok, nil} ->
            conn
            |> put_status(:ok)
            |> json(%{ok: false, reason: "no_ready"})

          {:ok, %Document{} = doc} ->
            json(conn, %{ok: true, doc: render_doc(doc)})

          {:error, reason} ->
            conn
            |> put_status(:conflict)
            |> json(%{ok: false, reason: reason_to_string(reason)})
        end

      _ ->
        bad_request(conn, "worker_id is required")
    end
  end

  # ─── POST /v1/tasks/:doc_id/close ───────────────────────────────────────

  def close(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, worker_id} <- fetch_string(params, "worker_id"),
         {:ok, observed_epoch} <- fetch_int(params, "observed_epoch"),
         {:ok, task} <- find_task_by_doc_id(doc_id, conn) do
      opts =
        [observed_epoch: observed_epoch]
        |> put_opt(:observed_rev, params["observed_rev"])
        |> put_opt(:lifecycle_status, params["lifecycle_status"])

      case Tasks.close(task.id, worker_id, opts) do
        {:ok, %Document{} = doc} ->
          json(conn, %{ok: true, doc: render_doc(doc)})

        {:error, reason} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, reason: reason_to_string(reason)})
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── GET /v1/tasks/:doc_id/edges ────────────────────────────────────────

  def edges(conn, %{"doc_id" => doc_id} = params) do
    kind_opt =
      case params["kind"] do
        nil -> :blocks
        "all" -> :all
        other when is_binary(other) -> other
      end

    case find_task_by_doc_id(doc_id, conn) do
      {:ok, task} ->
        deps = Tasks.dependencies(task.id, kind: kind_opt)
        dependents = Tasks.dependents(task.id, kind: kind_opt)

        json(conn, %{
          ok: true,
          dependencies: Enum.map(deps, &render_doc/1),
          dependents: Enum.map(dependents, &render_doc/1)
        })

      {:error, :not_found} ->
        not_found(conn, "task not found")
    end
  end

  # ─── POST /v1/tasks/edges ───────────────────────────────────────────────

  def add_edge(conn, params) do
    with {:ok, from_id} <- fetch_string(params, "from_id"),
         {:ok, to_id} <- fetch_string(params, "to_id"),
         {:ok, from_doc} <- find_task_by_doc_id(from_id, conn),
         {:ok, to_doc} <- find_task_by_doc_id(to_id, conn) do
      kind = params["kind"] || "blocks"

      case Tasks.add_dep(from_doc.id, to_doc.id, kind) do
        {:ok, %Edge{} = edge} ->
          json(conn, %{
            ok: true,
            edge: %{from_id: edge.from_id, to_id: edge.to_id, kind: edge.kind}
          })

        {:error, %Ecto.Changeset{} = cs} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{ok: false, reason: "invalid_edge", errors: changeset_errors(cs)})
      end
    else
      {:error, :missing, field} ->
        bad_request(conn, "#{field} is required")

      {:error, :not_found} ->
        not_found(conn, "from_id or to_id not found")
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────────────

  # Look up a task by its `doc_id` string. We DO NOT route through
  # `Content.get_document/4` here on purpose — the dataset-string filter in
  # Content threads through `resolve_read_dataset_id/2` which, for callers
  # carrying both workspace + project scope, can resolve the requested
  # dataset string to a DIFFERENT workspace's dataset_id (barkpark-sknf
  # shape). For the bd-shim surface, `doc_id` is unique within
  # `(workspace, project, type=task)` and the dataset string is incidental,
  # so we filter directly on the workspace + project ids (the hard tenant
  # boundary) and skip the dataset coalescence entirely.
  defp find_task_by_doc_id(doc_id, conn) do
    scope = scope_opts(conn)
    workspace_id = Keyword.get(scope, :workspace_id)
    project_id = Keyword.get(scope, :project_id)

    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task"
      )

    query =
      base
      |> maybe_filter_workspace(workspace_id)
      |> maybe_filter_project(project_id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Document{} = doc -> {:ok, doc}
    end
  end

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, ws_id),
    do: from(d in query, where: d.workspace_id == ^ws_id)

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, p_id),
    do: from(d in query, where: d.project_id == ^p_id)

  # Render a Document into the bd-compatible shape the shim consumes.
  # Keep the field set tight enough to translate cleanly into `bd show`
  # JSON, broad enough that callers like `bd list --json` don't lose
  # information (priority, assignee, content.kind for filtering).
  defp render_doc(%Document{} = doc) do
    content = doc.content || %{}

    %{
      id: doc.id,
      doc_id: doc.doc_id,
      title: doc.title,
      status: doc.status,
      type: doc.type,
      dataset: doc.dataset,
      rev: doc.rev,
      kind: Map.get(content, "kind"),
      lifecycle_status: Map.get(content, "lifecycle_status"),
      priority: Map.get(content, "priority"),
      assignee: Map.get(content, "assignee"),
      parent_id: Map.get(content, "parent_id"),
      claim: Map.get(content, "claim"),
      content: content,
      inserted_at: doc.inserted_at,
      updated_at: doc.updated_at
    }
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, :missing, key}
    end
  end

  defp fetch_int(params, key) do
    case Map.get(params, key) do
      n when is_integer(n) -> {:ok, n}
      s when is_binary(s) -> parse_int_strict(s, key)
      _ -> {:error, :missing, key}
    end
  end

  defp parse_int_strict(s, key) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :missing, key}
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> default
    end
  end

  defp parse_int(v, _default) when is_integer(v), do: v

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string({:invalid_lifecycle, s}), do: "invalid_lifecycle:#{s}"
  defp reason_to_string(other), do: inspect(other)

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, reason: "bad_request", message: message})
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> json(%{ok: false, reason: "not_found", message: message})
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
