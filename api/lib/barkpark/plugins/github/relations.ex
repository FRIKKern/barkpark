defmodule Barkpark.Plugins.Github.Relations do
  @moduledoc """
  Issue-tree relations for the GitHub bridge (epic charter Wave 5, D11 +
  D11-retry). Two jobs, both OUTBOUND and both structurally loop-safe:

    1. **Blocker-ref hydration** — `hydrate_blocker_refs/3` resolves a task's
       `blocks` blockers to their MIRRORED issue numbers and decorates the
       in-memory doc with `"blocker_issue_refs"`, the exact key the pure
       `Projection` reads (projection.ex L241) to render the
       `<!-- barkpark:blocks -->` body fence. It reads the DB but writes
       NOTHING — not to GitHub, not to the ledger. A blocker with no mirrored
       issue is simply OMITTED (never fabricate a ref — the projection's rule).

    2. **Native sub-issue linking** — `sync/5` mirrors `content.parent_id` to a
       native GitHub sub-issue. When the parent isn't mirrored yet it DEFERS
       (never errors, never guesses — the wiring retries per D11-retry); past a
       depth cap it CAP-FLATTENs to a body marker instead of a native link.

  ## Directional purity (D5)

  Every GitHub read here (`Client.get_issue` for the child's database id) is used
  ONLY to WRITE a link — never to write a GitHub value back into a task field.
  There is no reverse path. This module never mutates a task (D4): it decorates
  an in-memory map and calls GitHub; the `Link.put` bookkeeping stamp (which
  carries `source: "github"`, outbox-excluded) is the WIRING's job (slice 4).

  ## The `Client` seam

  The two sub-issue verbs (`get_issue`, `add_sub_issue`) are dispatched through a
  runtime-resolved module so this slice compiles and tests WITHOUT the Client
  transport slice in the tree: tests inject a stub via

      config :barkpark, #{inspect(__MODULE__)}, client: MyStubClient

  and runtime resolves to `Barkpark.Plugins.Github.Client`.
  """

  require Logger
  import Ecto.Query, only: [from: 2, subquery: 1]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Repo
  alias Barkpark.Plugins.Github.{Client, Link}

  @task_type "task"

  # Cap-flatten thresholds (D11). Overridable per-call for testing.
  @default_max_depth 8
  # Past this many DISTINCT children a parent cap-flattens instead of growing an
  # unwieldy native sub-issue tree. Overridable per-call (`:max_children`).
  @default_max_children 100

  # ---------------------------------------------------------------------------
  # Blocker-ref hydration
  # ---------------------------------------------------------------------------

  @doc """
  Decorate `task_doc` with `"blocker_issue_refs"` — the list of MIRRORED issue
  numbers of the task's `blocks` blockers — the exact key `Projection` renders
  the blocks fence from.

  Blocker doc_ids are gathered from BOTH substrate views the task plugin
  exposes: the flat `content.blocked_by` list AND the authoritative `task_edges`
  dependency graph (`Tasks.dependencies/2`). Each blocker is loaded DRAFT-FIRST
  (the `content.github` link is stamped on the draft row, so the published
  perspective can miss it), its `content.github.issue` read via `Link.get/1`,
  and the issue NUMBER collected. A blocker with NO mirrored issue is OMITTED —
  never fabricate a ref.

  Reads the DB; writes NOTHING (not GitHub, not the ledger). Returns a plain map
  (a `%Document{}` input is normalised to a projection-ready map) so the caller
  can hand it straight to `Projection.task_to_issue/1`.
  """
  @spec hydrate_blocker_refs(map(), String.t(), keyword()) :: map()
  def hydrate_blocker_refs(task_doc, dataset, opts \\ [])
      when is_map(task_doc) and is_binary(dataset) do
    refs =
      task_doc
      |> blocker_doc_ids()
      |> Enum.uniq()
      |> Enum.map(&mirrored_issue_number(&1, dataset, opts))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    task_doc
    |> to_plain_map()
    |> Map.put("blocker_issue_refs", refs)
  end

  # Union of the two blocker views: flat content.blocked_by + task_edges graph.
  defp blocker_doc_ids(task_doc) do
    content_blocked_by(task_doc) ++ edge_blocker_doc_ids(task_doc)
  end

  defp content_blocked_by(task_doc) do
    case get(content_of(task_doc), "blocked_by") do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      id when is_binary(id) and id != "" -> [id]
      _ -> []
    end
  end

  # Blockers from the authoritative task_edges graph (the `to_id` side of the
  # task's outbound `blocks` edges). Needs the task's uuid; a plain test map
  # without one simply yields no edge-blockers. Best-effort — a query hiccup
  # never breaks hydration (we still have content.blocked_by).
  defp edge_blocker_doc_ids(task_doc) do
    case task_uuid(task_doc) do
      uuid when is_binary(uuid) and uuid != "" ->
        try do
          Barkpark.Tasks.dependencies(uuid, kind: :blocks)
          |> Enum.map(& &1.doc_id)
          |> Enum.filter(&is_binary/1)
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end

  # Load a blocker DRAFT-FIRST and read its mirrored issue number, or nil.
  defp mirrored_issue_number(blocker_doc_id, dataset, opts) do
    with %Document{} = doc <- load_draft_first(blocker_doc_id, dataset, opts),
         gh when is_map(gh) <- Link.get(doc) do
      issue_num(Map.get(gh, "issue"))
    else
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Native parent_id → sub-issue linking (D11 + D11-retry)
  # ---------------------------------------------------------------------------

  @doc """
  Mirror `content.parent_id` to a native GitHub sub-issue link.

    * No `content.parent_id` → `:noop`.
    * Parent not mirrored yet (no `content.github.issue`) →
      `{:defer, :parent_unmirrored}` — the wiring mirrors the parent then retries
      the child (D11-retry). NEVER errors, NEVER guesses.
    * Parent chain deeper than the depth cap (default #{@default_max_depth}) OR
      the parent already carries more than #{@default_max_children} DISTINCT
      children → `{:flatten, parent_task_id}` — the wiring hydrates a
      `"parent_marker"` key and the projection renders a `<!-- barkpark:parent -->`
      body marker instead of a native link (graceful degradation, not a second
      linking system).
    * Otherwise: resolve the CHILD issue's database id via `Client.get_issue`
      (the sub-issues API keys on the child's db id, not its number) and
      `Client.add_sub_issue(repo, parent_number, child_db_id)`. A `422` is
      DISAMBIGUATED: an "already exists" body is idempotent → `:ok`; a real
      rejection (any other legible 422 detail) → `{:error, {:sub_issue_rejected,
      parent_num, child_db_id, detail}}` so the wiring RECORDS it. A 422 with no
      legible detail stays conservatively idempotent → `:ok`.

  `opts` accepts `:max_parent_depth` (override the depth cap) and is threaded to
  `Content.get_document/4` (scope) and the `Client` verbs (HTTP tuning / test
  seam). This function calls GitHub and reads the DB; it stamps NOTHING — the
  optional `sub_issue_parent` dedup stamp is the wiring's `source: "github"`
  write.
  """
  @spec sync(map(), String.t(), integer() | String.t(), String.t(), keyword()) ::
          :ok | :noop | {:defer, :parent_unmirrored} | {:flatten, String.t()} | {:error, term()}
  def sync(task_doc, repo, issue_number, dataset, opts \\ [])
      when is_map(task_doc) and is_binary(repo) and is_binary(dataset) do
    case parent_id(task_doc) do
      pid when is_binary(pid) and pid != "" ->
        sync_parent(task_doc, pid, repo, issue_number, dataset, opts)

      _ ->
        :noop
    end
  end

  defp sync_parent(task_doc, parent_doc_id, repo, issue_number, dataset, opts) do
    case parent_issue_number(parent_doc_id, dataset, opts) do
      nil ->
        # Parent unmirrored (or gone) — DEFER; the wiring mirrors it + retries,
        # bounded by relink_attempt so it can never loop forever (D11-retry).
        {:defer, :parent_unmirrored}

      parent_num ->
        if depth_exceeded?(task_doc, dataset, opts) or
             child_count_exceeded?(parent_doc_id, dataset, opts) do
          {:flatten, parent_doc_id}
        else
          link_sub_issue(repo, parent_num, issue_number, opts)
        end
    end
  end

  defp parent_issue_number(parent_doc_id, dataset, opts) do
    case load_draft_first(parent_doc_id, dataset, opts) do
      %Document{} = parent ->
        case Link.get(parent) do
          gh when is_map(gh) -> issue_num(Map.get(gh, "issue"))
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Resolve the child issue's database id, then link it under the parent number.
  defp link_sub_issue(repo, parent_num, child_number, opts) do
    case client_mod().get_issue(repo, child_number, opts) do
      {:ok, issue} ->
        case child_db_id(issue) do
          nil ->
            # No db id on the issue node — we can't link without it. This never
            # fails the issue mirror (the wiring swallows/logs relations errors);
            # skip cleanly so the body still mirrors.
            Logger.warning(
              "github relations: issue ##{child_number} carries no database id; " <>
                "skipping sub-issue link under ##{parent_num}"
            )

            :ok

          db_id ->
            add_sub_issue(repo, parent_num, db_id, opts)
        end

      {:error, err} ->
        {:error, err}
    end
  end

  defp add_sub_issue(repo, parent_num, child_db_id, opts) do
    case client_mod().add_sub_issue(repo, parent_num, child_db_id, opts) do
      {:ok, _} -> :ok
      {:error, %{reason: {:http, 422}} = err} -> classify_422(err, parent_num, child_db_id)
      {:error, err} -> {:error, err}
    end
  end

  # A 422 from the sub-issues API is AMBIGUOUS: GitHub returns it BOTH for
  # "already a sub-issue" (idempotent — the link we wanted already exists) AND
  # for a genuine rejection (the child can't be a sub-issue of that parent, a
  # cycle, etc.). Distinguish on whatever legible detail the error surfaces:
  #
  #   * a message/errors body indicating the link already exists → `:ok`
  #     (idempotent — re-linking is a no-op success);
  #   * any OTHER legible detail → `{:error, {:sub_issue_rejected, …}}` so the
  #     wiring RECORDS a quarantine row (an operator sees why the tree link never
  #     formed — a real 422 was silently swallowed as success before);
  #   * NO legible detail (the common case — the REST `Client` discards the 422
  #     body, so a `%NetworkError{}` carries only `reason: {:http, 422}`) → stay
  #     CONSERVATIVE and treat it as idempotent `:ok`, exactly as before. We never
  #     fabricate a rejection we can't substantiate.
  defp classify_422(err, parent_num, child_db_id) do
    case error_detail_text(err) do
      nil ->
        :ok

      detail ->
        if already_exists?(detail) do
          :ok
        else
          {:error, {:sub_issue_rejected, parent_num, child_db_id, detail}}
        end
    end
  end

  # Pull a human-readable detail string out of the error for the already/exists
  # test. Reads the conventional GitHub error shapes DEFENSIVELY via a key-tolerant
  # getter (atom or string), WITHOUT assuming the `NetworkError` struct grows a
  # field it does not have today — a plain-map error (what tests inject, what a
  # richer client might return) is tolerated too. `nil` when nothing legible is
  # present, so `classify_422` falls to the conservative `:ok`.
  defp error_detail_text(err) when is_map(err) do
    [
      err_get(err, :message),
      body_text(err_get(err, :body)),
      errors_text(err_get(err, :errors))
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      parts -> parts |> Enum.join(" ") |> String.trim()
    end
  end

  defp error_detail_text(_), do: nil

  # A body may be a raw string, or a decoded map carrying `message`/`errors`.
  defp body_text(b) when is_binary(b), do: b

  defp body_text(b) when is_map(b) do
    [err_get(b, :message), errors_text(err_get(b, :errors))]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> nil_if_blank()
  end

  defp body_text(_), do: nil

  # `errors` (GitHub's validation array) may be a list of maps or bare strings.
  defp errors_text(list) when is_list(list) do
    list
    |> Enum.map(fn
      m when is_map(m) -> err_get(m, :message) || err_get(m, :code) || err_get(m, :type)
      s when is_binary(s) -> s
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> nil_if_blank()
  end

  defp errors_text(_), do: nil

  defp already_exists?(detail) do
    d = String.downcase(detail)
    String.contains?(d, "already") or String.contains?(d, "exist")
  end

  # Key-tolerant getter (atom key first — error structs/maps carry atom keys —
  # then the string key a JSON-decoded body carries).
  defp err_get(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      v -> v
    end
  end

  defp err_get(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp nil_if_blank(s) do
    if blank?(s), do: nil, else: s
  end

  # ---------------------------------------------------------------------------
  # Cap-flatten (D11): bound the parent chain walk
  # ---------------------------------------------------------------------------

  # True when the task's ANCESTOR chain (walking content.parent_id upward) is
  # deeper than the cap. The walk is bounded by `cap = max + 1` so it stops early
  # and a parent_id cycle can never spin.
  defp depth_exceeded?(task_doc, dataset, opts) do
    max = max_depth(opts)
    ancestor_depth(parent_id(task_doc), dataset, opts, 0, max + 1) > max
  end

  # True when the parent already carries MORE than the child cap of DISTINCT
  # children. Both the draft (`drafts.<id>`) and published (`<id>`) row of a child
  # carry the SAME `content.parent_id`, so a naive row count double-counts every
  # child that has an open draft; we count DISTINCT prefix-normalized `doc_id`s
  # (grouping collapses the twin). Bounded by a `LIMIT cap+1` subquery — we only
  # need the ">cap?" answer, never the true total, so a parent with thousands of
  # children never scans them all. Scoped fail-OPEN on an absent workspace,
  # matching the draft-first reads elsewhere in this module (a default-scope run
  # counts across the tenant exactly as `Content.get_document` reads it).
  defp child_count_exceeded?(parent_doc_id, dataset, opts)
       when is_binary(parent_doc_id) and parent_doc_id != "" do
    max = max_children(opts)

    distinct_children =
      from(d in Document,
        where: d.type == ^@task_type and d.dataset == ^dataset,
        where:
          fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) ==
            fragment("regexp_replace(?, '^drafts\\.', '')", ^parent_doc_id),
        group_by: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
        select: %{id: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id)},
        limit: ^(max + 1)
      )
      |> Scope.scope_to_workspace_or_global(
        Keyword.get(opts, :workspace_id),
        Keyword.get(opts, :project_id)
      )

    count = Repo.one(from(c in subquery(distinct_children), select: count()))

    (count || 0) > max
  end

  defp child_count_exceeded?(_parent_doc_id, _dataset, _opts), do: false

  defp ancestor_depth(pid, dataset, opts, acc, cap)
       when is_binary(pid) and pid != "" and acc < cap do
    next =
      case load_draft_first(pid, dataset, opts) do
        %Document{content: content} -> content_parent_id(content)
        _ -> nil
      end

    ancestor_depth(next, dataset, opts, acc + 1, cap)
  end

  defp ancestor_depth(_pid, _dataset, _opts, acc, _cap), do: acc

  defp max_depth(opts) do
    case Keyword.get(opts, :max_parent_depth) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max_depth
    end
  end

  defp max_children(opts) do
    case Keyword.get(opts, :max_children) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max_children
    end
  end

  # ---------------------------------------------------------------------------
  # Loading + shape helpers
  # ---------------------------------------------------------------------------

  defp load_draft_first(doc_id, dataset, opts) do
    published = Content.published_id(doc_id)

    case Content.get_document(Content.draft_id(published), @task_type, dataset, opts) do
      {:ok, %Document{} = d} ->
        d

      _ ->
        case Content.get_document(published, @task_type, dataset, opts) do
          {:ok, %Document{} = d} -> d
          _ -> nil
        end
    end
  end

  # Normalise the child's GitHub database id (integer). GitHub's sub-issues API
  # keys on this, NOT the issue number.
  defp child_db_id(issue) when is_map(issue) do
    case Map.get(issue, "id") || Map.get(issue, :id) do
      id when is_integer(id) and id > 0 -> id
      _ -> nil
    end
  end

  defp child_db_id(_), do: nil

  # An issue number may be stored as an integer (canonical) or a numeric string.
  defp issue_num(n) when is_integer(n) and n > 0, do: n

  defp issue_num(s) when is_binary(s) do
    case Integer.parse(String.trim_leading(s, "#")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp issue_num(_), do: nil

  defp parent_id(task_doc), do: content_parent_id(content_of(task_doc))

  defp content_parent_id(content) when is_map(content) do
    case get(content, "parent_id") do
      pid when is_binary(pid) and pid != "" -> pid
      _ -> nil
    end
  end

  defp content_parent_id(_), do: nil

  defp content_of(%Document{content: content}) when is_map(content), do: content
  defp content_of(%{content: content}) when is_map(content), do: content
  defp content_of(%{"content" => content}) when is_map(content), do: content
  defp content_of(_), do: %{}

  defp task_uuid(%Document{id: id}), do: id
  defp task_uuid(%{id: id}), do: id
  defp task_uuid(%{"id" => id}), do: id
  defp task_uuid(_), do: nil

  # Normalise the decoration target to a plain, projection-ready map. A
  # `%Document{}` becomes a plain map (dropping the struct) so the projection's
  # key-tolerant reader finds `content`/`doc_id` (atom keys) alongside the string
  # `"blocker_issue_refs"` key hydration adds — without corrupting a struct.
  defp to_plain_map(%Document{} = d), do: Map.from_struct(d)
  defp to_plain_map(m) when is_map(m), do: m

  # ---------------------------------------------------------------------------
  # Client seam
  # ---------------------------------------------------------------------------

  defp client_mod do
    Application.get_env(:barkpark, __MODULE__, [])[:client] || Client
  end

  # ---------------------------------------------------------------------------
  # Key-tolerant accessor (mirrors Projection's — string key then existing atom)
  # ---------------------------------------------------------------------------

  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, safe_atom(key))
    end
  end

  defp get(_, _), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
