defmodule Barkpark.Content.Papers.BodyLosses do
  @moduledoc """
  For one Paper, the list item children and callout bodies that disappeared
  between its stored states. Read-only: it reads `revisions` and the Paper's
  row and writes nothing.

  The owner decides when it runs against a real database; agents run it only
  in tests, on the local test database.

  The states are the Paper's revisions, oldest first, then its row as it is
  now. The read finds the one Paper first, then its revisions in its own
  workspace, project and dataset; when more than one Paper is stored under
  the slug, the report is one line naming how many and the scope options. A
  step runs from one state to the next.

  A BPML push records the Paper as it stood before it and as it left it, in
  one transaction (`Papers.PushRevision.actions/0`: the before row, then the
  `after_action/0` row). A step from such a before row to its after row is that
  push alone, and is named as a push. A push recorded before the after row
  existed left only its before row: the report prints it as "after not
  recorded", and the step from it is not named as a push, because it holds
  the push and any writes after it. Every other step may hold several writes
  of any kind, among them a push that recorded no revision at all, so those
  cannot be told apart; the report prints that limit.

  What counts as lost:

    * a list item that held child blocks and, in the next state, is still in
      its list (found by its text, else by its place) with none;
    * a callout whose body held blocks and, in the next state, is still there
      (by id) with an empty body.

  A list or callout removed whole is a removed block, not counted here.
  """

  import Ecto.Query

  alias Barkpark.Content.{Document, DraftId, Revision}
  alias Barkpark.Content.Papers.PushRevision
  alias Barkpark.Repo

  # Both push actions come from the one list (`PushRevision.actions/0`): the
  # after row by `after_action/0`, the before row as the other one. A third
  # action on that list fails this match at compile time.
  @after_row PushRevision.after_action()
  [before_row] = PushRevision.actions() -- [@after_row]
  @before_row before_row

  @doc """
  The report for `slug` in `dataset`, as lines. `opts` may scope the read
  with `:workspace_id` and `:project_id`.
  """
  @spec report(String.t(), String.t(), keyword()) :: [String.t()]
  def report(slug, dataset \\ "production", opts \\ []) do
    case states(slug, dataset, opts) do
      {:many, n} ->
        [
          "#{n} Papers are stored as #{slug} (#{dataset}) in different workspaces or projects; " <>
            "pass :workspace_id and :project_id to read one."
        ]

      {:ok, states} ->
        lines(slug, dataset, states)
    end
  end

  defp lines(slug, dataset, states) do
    {pushes, unpaired} = pushes(states)

    header = [
      "Paper #{slug} (#{dataset}): #{length(states)} stored states, #{length(pushes)} BPML " <>
        "pushes recorded before and after, #{length(unpaired)} with the state before only.",
      "A step that is not a #{@before_row} -> #{@after_row} pair may hold any writes, a push that " <>
        "recorded no revision among them; those cannot be told apart."
    ]

    old = for a <- unpaired, do: "BPML push, #{a.label}: after not recorded."

    lines =
      for {step, losses} <- steps(states), loss <- losses do
        "#{step}: #{loss}"
      end

    header ++
      old ++
      if(lines == [], do: ["No list item children or callout bodies disappeared."], else: lines)
  end

  # The before rows with their after row next (`{a, b}` pairs), and those
  # without one.
  defp pushes(states) do
    pairs = Enum.zip(states, Enum.drop(states, 1) ++ [nil])

    {for({%{action: @before_row} = a, %{action: @after_row} = b} <- pairs, do: {a, b}),
     for(
       {%{action: @before_row} = a, next} <- pairs,
       not match?(%{action: @after_row}, next),
       do: a
     )}
  end

  @doc """
  The steps between consecutive `states` (each a map with `:label`, `:action`
  and `:blocks`) that lost something: `[{step_label, [loss]}]`.
  """
  @spec steps([map()]) :: [{String.t(), [String.t()]}]
  def steps(states) do
    states
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> {step_label(a, b), losses(a.blocks, b.blocks)} end)
    |> Enum.reject(fn {_label, losses} -> losses == [] end)
  end

  defp step_label(%{action: @before_row} = a, %{action: @after_row} = b),
    do: "BPML push, #{a.label} -> #{b.label}"

  defp step_label(%{action: @before_row} = a, b),
    do: "a BPML push (after not recorded) and any writes after it, #{a.label} -> #{b.label}"

  defp step_label(a, b), do: "not a recorded push, #{a.label} -> #{b.label}"

  @doc "What `before` held that `after_` lost, as readable lines."
  @spec losses([map()], [map()]) :: [String.t()]
  def losses(before, after_) do
    item_losses(before, after_) ++ body_losses(before, after_)
  end

  # ── list item children ──────────────────────────────────────────────────────

  defp item_losses(before, after_) do
    later = after_ |> lists() |> Map.new(fn {key, _path, items} -> {key, items} end)

    for {key, path, items} <- lists(before),
        {item, i} <- Enum.with_index(items),
        children(item) != [],
        Map.has_key?(later, key),
        lost_children?(item, i, later[key]) do
      n = length(children(item))
      "#{path} item #{i} (\"#{text(item)}\") lost its #{n} child block#{plural(n)}"
    end
  end

  # Every list block at any depth: {key, path, items}; the key is its id, or
  # its path when it has none.
  defp lists(blocks), do: walk(blocks, "blocks", &list_entry/2)

  defp list_entry(%{"type" => "list", "items" => items} = b, path) when is_list(items),
    do: [{b["id"] || path, path, items}]

  defp list_entry(_node, _path), do: []

  # The item still in the list, found by its text, else by its place, holds
  # no child blocks.
  defp lost_children?(item, i, items) do
    t = text(item)

    case Enum.find(items, &(text(&1) == t)) || Enum.at(items, i) do
      nil -> false
      match -> children(match) == []
    end
  end

  defp children(%{"children" => c}) when is_list(c), do: c
  defp children(_item), do: []

  # ── callout bodies ──────────────────────────────────────────────────────────

  defp body_losses(before, after_) do
    later = after_ |> walk("blocks", &callout_entry/2) |> Map.new(fn {id, _p, n} -> {id, n} end)

    for {id, path, n} <- walk(before, "blocks", &callout_entry/2),
        n > 0,
        Map.get(later, id) == 0 do
      "#{path} callout #{id} lost its body (#{n} block#{plural(n)})"
    end
  end

  defp callout_entry(%{"type" => "callout", "id" => id} = c, path) when is_binary(id) do
    n = c |> Map.get("slots", %{}) |> body_count()
    [{id, path, n}]
  end

  defp callout_entry(_node, _path), do: []

  defp body_count(%{} = slots),
    do: slots |> Map.values() |> Enum.map(&length(List.wrap(&1))) |> Enum.sum()

  defp body_count(_slots), do: 0

  # ── walking ─────────────────────────────────────────────────────────────────

  # `fun` on every map at any depth, with its path, concatenated.
  defp walk(%{} = map, path, fun) do
    fun.(map, path) ++
      Enum.flat_map(Enum.sort(map), fn {k, v} -> walk(v, "#{path}.#{k}", fun) end)
  end

  defp walk(list, path, fun) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> walk(v, "#{path}[#{i}]", fun) end)

  defp walk(_other, _path, _fun), do: []

  # An item's own words: its text, value and content, never its children.
  defp text(%{} = m), do: m |> Map.take(["text", "value", "content"]) |> Map.values() |> text()
  defp text(l) when is_list(l), do: Enum.map_join(l, &text/1)
  defp text(s) when is_binary(s), do: s
  defp text(_other), do: ""

  defp plural(1), do: ""
  defp plural(_n), do: "s"

  # ── reading ─────────────────────────────────────────────────────────────────

  # The one Paper's states: its revisions in its own workspace, project and
  # dataset, then its row. With no row, the revisions must all share one
  # workspace and project. `{:many, n}` when the read finds more than one.
  defp states(slug, dataset, opts) do
    id = DraftId.published_id(slug)

    revisions =
      from(r in Revision,
        where: r.doc_id == ^id and r.type == "paper" and r.dataset == ^dataset,
        order_by: [asc: r.inserted_at, asc: r.id]
      )
      |> scoped(opts)

    rows =
      from(d in Document, where: d.doc_id == ^id and d.type == "paper" and d.dataset == ^dataset)
      |> scoped(opts)
      |> Repo.all()

    case rows do
      [row] ->
        {:ok,
         revisions
         |> same_scope(row)
         |> revision_states()
         |> Kernel.++([state(nil, "the Paper now", row)])}

      [] ->
        found = Repo.all(revisions)

        case found |> Enum.uniq_by(&{&1.workspace_id, &1.project_id}) |> length() do
          n when n > 1 -> {:many, n}
          _one_or_none -> {:ok, found |> in_order() |> Enum.map(&revision_state/1)}
        end

      many ->
        {:many, length(many)}
    end
  end

  defp revision_states(query),
    do: query |> Repo.all() |> in_order() |> Enum.map(&revision_state/1)

  # Oldest first. When a push's two rows carry the same instant, its before
  # row goes first.
  defp in_order(revisions) do
    Enum.sort_by(revisions, fn r ->
      {DateTime.to_unix(r.inserted_at, :microsecond), if(r.action == @after_row, do: 1, else: 0)}
    end)
  end

  defp revision_state(r),
    do: state(r.action, "revision #{r.id} (#{r.action}, #{r.inserted_at})", r)

  # Revisions in `row`'s workspace and project, and in its dataset (or with
  # none, read by the dataset string).
  defp same_scope(query, row) do
    query = query |> same(:workspace_id, row.workspace_id) |> same(:project_id, row.project_id)

    case row.dataset_id do
      nil -> query
      ds -> from(r in query, where: r.dataset_id == ^ds or is_nil(r.dataset_id))
    end
  end

  defp same(query, key, nil), do: from(r in query, where: is_nil(field(r, ^key)))
  defp same(query, key, value), do: from(r in query, where: field(r, ^key) == ^value)

  defp state(action, label, %{content: content}),
    do: %{action: action, label: label, blocks: List.wrap(get_in(content || %{}, ["blocks"]))}

  defp scoped(query, opts) do
    Enum.reduce([:workspace_id, :project_id], query, fn key, q ->
      case Keyword.get(opts, key) do
        nil -> q
        value -> from(r in q, where: field(r, ^key) == ^value)
      end
    end)
  end
end
