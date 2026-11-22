defmodule Barkpark.Content.Papers.BodyLosses do
  @moduledoc """
  For one Paper, the list item children and callout bodies that disappeared
  between its stored states. Read-only: it reads `revisions` and the Paper's
  row and writes nothing.

  The owner decides when it runs against a real database; agents run it only
  in tests, on the local test database.

  The states are the Paper's revisions, oldest first, then its row as it is
  now. A step runs from one state to the next. Since a BPML push records the
  Paper as it stood before it (`Papers.PushRevision`, action `"bpml-push"`), a
  step that starts at a `bpml-push` revision starts with that push. Any other
  step may hold several writes of any kind, and a push older than those
  revisions left none, so it cannot be told apart from other writes; the
  report prints that limit.

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

  @push PushRevision.action()

  @doc """
  The report for `slug` in `dataset`, as lines. `opts` may scope the read
  with `:workspace_id` and `:project_id`.
  """
  @spec report(String.t(), String.t(), keyword()) :: [String.t()]
  def report(slug, dataset \\ "production", opts \\ []) do
    states = states(slug, dataset, opts)
    steps = steps(states)
    pushes = Enum.count(states, &(&1.action == @push))

    header = [
      "Paper #{slug} (#{dataset}): #{length(states)} stored states, #{pushes} recorded BPML pushes.",
      "A step that does not start at a bpml-push revision may hold any writes, a push older " <>
        "than the bpml-push revisions among them; those cannot be told apart."
    ]

    lines =
      for {step, losses} <- steps, loss <- losses do
        "#{step}: #{loss}"
      end

    header ++
      if(lines == [], do: ["No list item children or callout bodies disappeared."], else: lines)
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

  defp step_label(%{action: @push} = a, b), do: "BPML push, #{a.label} -> #{b.label}"
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

  defp states(slug, dataset, opts) do
    id = DraftId.published_id(slug)

    revisions =
      from(r in Revision,
        where: r.doc_id == ^id and r.type == "paper" and r.dataset == ^dataset,
        order_by: [asc: r.inserted_at, asc: r.id]
      )
      |> scoped(opts)
      |> Repo.all()
      |> Enum.map(&state(&1.action, "revision #{&1.id} (#{&1.action}, #{&1.inserted_at})", &1))

    row =
      from(d in Document, where: d.doc_id == ^id and d.type == "paper" and d.dataset == ^dataset)
      |> scoped(opts)
      |> Repo.one()

    revisions ++ if(row, do: [state(nil, "the Paper now", row)], else: [])
  end

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
