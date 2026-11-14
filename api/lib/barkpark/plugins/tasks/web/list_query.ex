defmodule Barkpark.Plugins.Tasks.Web.ListQuery do
  @moduledoc """
  The URL state and the paged SQL read behind the Tasks list page
  (`Barkpark.Plugins.Tasks.Web.ListLive`).

  The board loads its whole corpus and shows 12 done tasks. This read pages in
  SQL instead: one count, one page of rows, and one lookup for the parent
  titles of that page. It never loads the whole task ledger.

  ## Scope

  The same rows the board reads: `type == "task"` in the board's dataset,
  every workspace on the operator's flat mount and one workspace on a scoped
  mount (`BarkparkWeb.OpsOperatorGate.scoped_workspace_id/1`). Draft twins
  collapse through `Barkpark.Tasks.Query.collapse_twins/1`, the same rule the
  `/v1/tasks` index uses.

  ## Field visibility

  `readable?` is the board's fail-closed predicate
  (`Barkpark.Tasks.Board.field_visibility_gate/1`). A field the reader may not
  see is left out of the row, and its filter and sort are dropped in
  `parse/2`, so a hidden value cannot be found by narrowing the count either.
  Title, doc id and lifecycle status are the fields the board shows ungated.
  The criteria count is ungated on the board too; it carries no text.

  ## Search

  `q` is a case-insensitive substring match on the title and the doc id. The
  description is not searched: it has no index, and a scan of every task body
  per keystroke is the cost this page exists to avoid.
  """

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Content.DraftId
  alias Barkpark.Repo
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Query

  @page_size 50
  @sorts ~w(updated priority title)
  @label_cap 3

  @type filters :: %{
          q: String.t(),
          statuses: [String.t()],
          priorities: [String.t()],
          assignee: String.t(),
          label: String.t(),
          parent: nil | :none | String.t(),
          sort: String.t(),
          dir: :asc | :desc,
          page: pos_integer()
        }

  @doc "Rows per page."
  def page_size, do: @page_size

  @doc "The lifecycle statuses a task can hold, in the schema's own order."
  def statuses, do: Tasks.lifecycle_statuses()

  @doc "The priorities the filter offers."
  def priorities, do: ~w(0 1 2 3 4)

  @doc """
  Parse URL params into the filter map. Unknown statuses, sorts and directions
  are dropped, never turned into atoms. A filter on a field `readable?` denies
  is dropped too.
  """
  @spec parse(map(), (String.t() -> boolean())) :: filters()
  def parse(params, readable?) when is_map(params) and is_function(readable?, 1) do
    worker? = readable?.("assignee") and readable?.("claim")
    priority? = readable?.("priority")
    sort = parse_sort(params["sort"], priority?)

    %{
      q: text(params["q"]),
      statuses: Enum.filter(csv(params["status"]), &(&1 in statuses())),
      priorities: if(priority?, do: Enum.filter(csv(params["priority"]), &digits?/1), else: []),
      assignee: if(worker?, do: text(params["assignee"]), else: ""),
      label: if(readable?.("labels"), do: text(params["label"]), else: ""),
      parent: if(readable?.("parent_id"), do: parse_parent(params["parent"])),
      sort: sort,
      dir: parse_dir(params["dir"], sort),
      page: parse_page(params["page"])
    }
  end

  @doc "The filter map as URL params, with every default left out."
  @spec to_params(filters()) :: [{String.t(), String.t()}]
  def to_params(f) do
    [
      {"q", f.q},
      {"status", Enum.join(f.statuses, ",")},
      {"priority", Enum.join(f.priorities, ",")},
      {"assignee", f.assignee},
      {"label", f.label},
      {"parent", parent_param(f.parent)},
      {"sort", if(f.sort == "updated", do: "", else: f.sort)},
      {"dir", if(f.dir == default_dir(f.sort), do: "", else: Atom.to_string(f.dir))},
      {"page", if(f.page == 1, do: "", else: Integer.to_string(f.page))}
    ]
    |> Enum.reject(fn {_k, v} -> v == "" end)
  end

  @doc "True when any search or filter narrows the list."
  @spec filtered?(filters()) :: boolean()
  def filtered?(f) do
    f.q != "" or f.statuses != [] or f.priorities != [] or f.assignee != "" or f.label != "" or
      f.parent != nil
  end

  @doc "The direction a sort starts in: newest first, lowest priority number first, A to Z."
  def default_dir("updated"), do: :desc
  def default_dir(_), do: :asc

  @doc """
  One page of rows plus the match count.

  `opts`: `:dataset` (required), `:workspace_id` (nil reads every workspace),
  `:readable?` (required, the field-visibility predicate).
  Returns `%{rows, total, page, pages}`; a page past the end is clamped to the
  last one.
  """
  @spec page(filters(), keyword()) :: %{
          rows: [map()],
          total: non_neg_integer(),
          page: pos_integer(),
          pages: pos_integer()
        }
  def page(filters, opts) do
    dataset = Keyword.fetch!(opts, :dataset)
    readable? = Keyword.fetch!(opts, :readable?)
    ws_id = Keyword.get(opts, :workspace_id)

    matched = dataset |> scope(ws_id) |> apply_filters(filters)
    total = Repo.aggregate(matched, :count)
    pages = max(1, ceil(total / @page_size))
    page = min(filters.page, pages)

    docs =
      from(d in matched,
        order_by: ^order(filters),
        limit: ^@page_size,
        offset: ^((page - 1) * @page_size)
      )
      |> Repo.all()

    parent_ids = if readable?.("parent_id"), do: parent_ids(docs), else: []
    titles = parent_titles(parent_ids, dataset, ws_id)

    %{rows: Enum.map(docs, &row(&1, titles, readable?)), total: total, page: page, pages: pages}
  end

  # ── scope ───────────────────────────────────────────────────────────────────

  defp scope(dataset, ws_id) do
    from(d in Document, where: d.type == "task" and d.dataset == ^dataset)
    |> clamp_workspace(ws_id)
    |> Query.collapse_twins()
  end

  defp clamp_workspace(query, nil), do: query

  defp clamp_workspace(query, ws_id) when is_binary(ws_id),
    do: from(d in query, where: d.workspace_id == ^ws_id)

  # ── filters ─────────────────────────────────────────────────────────────────

  defp apply_filters(query, f) do
    query
    |> filter_text(f.q)
    |> filter_statuses(f.statuses)
    |> filter_priorities(f.priorities)
    |> filter_assignee(f.assignee)
    |> Query.maybe_filter_label(f.label)
    |> filter_parent(f.parent)
  end

  defp filter_text(query, ""), do: query

  defp filter_text(query, q) do
    pattern = "%" <> escape_like(q) <> "%"

    from(d in query,
      where:
        ilike(d.title, ^pattern) or
          fragment("regexp_replace(?, '^drafts\\.', '') ILIKE ?", d.doc_id, ^pattern)
    )
  end

  defp filter_statuses(query, []), do: query

  defp filter_statuses(query, statuses) do
    from(d in query,
      where: fragment("COALESCE(?->>'lifecycle_status', 'open')", d.content) in ^statuses
    )
  end

  defp filter_priorities(query, []), do: query

  defp filter_priorities(query, priorities),
    do: from(d in query, where: fragment("?->>'priority'", d.content) in ^priorities)

  defp filter_assignee(query, ""), do: query

  # The board's worker is `assignee`, else the claim holder (`Board.to_card/5`).
  defp filter_assignee(query, worker) do
    from(d in query,
      where:
        fragment("COALESCE(?->>'assignee', ?->'claim'->>'worker')", d.content, d.content) ==
          ^worker
    )
  end

  defp filter_parent(query, nil), do: query

  defp filter_parent(query, :none),
    do: from(d in query, where: fragment("COALESCE(?->>'parent_id', '') = ''", d.content))

  defp filter_parent(query, parent_id), do: Query.maybe_filter_parent_id(query, parent_id)

  defp escape_like(s), do: String.replace(s, ["\\", "%", "_"], fn c -> "\\" <> c end)

  # ── order ───────────────────────────────────────────────────────────────────

  # `d.id` ends every order so two rows with equal keys never swap pages.
  defp order(%{sort: "title", dir: dir}) do
    [{nulls_last(dir), dynamic([d], fragment("lower(?)", d.title))}, {:asc, :id}]
  end

  # A priority that is not a small whole number sorts with the tasks that have none.
  defp order(%{sort: "priority", dir: dir}) do
    priority =
      dynamic(
        [d],
        fragment(
          "CASE WHEN ?->>'priority' ~ '^[0-9]{1,6}$' THEN (?->>'priority')::int END",
          d.content,
          d.content
        )
      )

    [{nulls_last(dir), priority}, {:desc, :updated_at}, {:desc, :id}]
  end

  defp order(%{dir: dir}), do: [{dir, :updated_at}, {dir, :id}]

  defp nulls_last(:asc), do: :asc_nulls_last
  defp nulls_last(:desc), do: :desc_nulls_last

  # ── rows ────────────────────────────────────────────────────────────────────

  defp parent_ids(docs) do
    docs
    |> Enum.map(&parent_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parent_of(%Document{content: content}) do
    case Map.get(content || %{}, "parent_id") do
      id when is_binary(id) and id != "" -> DraftId.published_id(id)
      _ -> nil
    end
  end

  # One query for every parent title on the page, held to the same dataset and
  # workspace as the rows. A published row's title wins over its draft twin's.
  defp parent_titles([], _dataset, _ws_id), do: %{}

  defp parent_titles(ids, dataset, ws_id) do
    from(d in Document,
      where:
        d.type == "task" and d.dataset == ^dataset and
          fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id) in ^ids,
      select: {d.doc_id, d.title}
    )
    |> clamp_workspace(ws_id)
    |> Repo.all()
    |> Enum.sort_by(fn {doc_id, _title} -> if DraftId.draft?(doc_id), do: 0, else: 1 end)
    |> Map.new(fn {doc_id, title} -> {DraftId.published_id(doc_id), title} end)
  end

  defp row(%Document{} = doc, titles, readable?) do
    content = doc.content || %{}
    parent_id = if readable?.("parent_id"), do: parent_of(doc)
    labels = if readable?.("labels"), do: labels(content), else: []

    %{
      doc_id: DraftId.published_id(doc.doc_id),
      title: doc.title,
      status: Map.get(content, "lifecycle_status") || "open",
      priority: if(readable?.("priority"), do: Map.get(content, "priority")),
      worker: worker(content, readable?),
      parent_id: parent_id,
      parent_title: parent_id && Map.get(titles, parent_id),
      labels: Enum.take(labels, @label_cap),
      more_labels: max(0, length(labels) - @label_cap),
      criteria: Tasks.criteria_progress(content),
      updated_at: doc.updated_at
    }
  end

  # Hidden unless BOTH sources are readable, as on the board card.
  defp worker(content, readable?) do
    if readable?.("assignee") and readable?.("claim") do
      Map.get(content, "assignee") || get_in(content, ["claim", "worker"])
    end
  end

  defp labels(content) do
    case Map.get(content, "labels") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  # ── param parsing ───────────────────────────────────────────────────────────

  defp text(raw) when is_binary(raw), do: raw |> String.trim() |> String.slice(0, 200)
  defp text(_), do: ""

  defp csv(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp csv(_), do: []

  defp digits?(s), do: s =~ ~r/\A[0-9]{1,6}\z/

  defp parse_parent("none"), do: :none

  defp parse_parent(raw) when is_binary(raw) do
    case text(raw) do
      "" -> nil
      id -> id
    end
  end

  defp parse_parent(_), do: nil

  defp parent_param(nil), do: ""
  defp parent_param(:none), do: "none"
  defp parent_param(id), do: id

  defp parse_sort("priority", false), do: "updated"
  defp parse_sort(raw, _priority?) when raw in @sorts, do: raw
  defp parse_sort(_, _priority?), do: "updated"

  defp parse_dir("asc", _sort), do: :asc
  defp parse_dir("desc", _sort), do: :desc
  defp parse_dir(_, sort), do: default_dir(sort)

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 -> min(n, 100_000)
      _ -> 1
    end
  end

  defp parse_page(_), do: 1
end
