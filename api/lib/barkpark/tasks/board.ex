defmodule Barkpark.Tasks.Board do
  @moduledoc """
  The pure organizer behind Barkpark Projects — the native task BOARD.

  This is the substrate logic for the kanban over the REAL `type:task`
  documents (the source of truth). It splits cleanly in two, mirroring the
  Bulldocs/Tasks "core owns machinery, plugin owns wiring" doctrine so the
  momentum/ready maths is unit-testable without a socket and shareable with the
  `task-board` PortableDoc component and any future web surface:

    * `build/2` — a deterministic, `now`-injected, LiveView-free function:
      bucketing + the derived `ready` overlay + momentum + per-card projection.
      PURE — no DB, no clock (the caller injects `opts[:now]`).
    * `snapshot/1` — the thin impure loader over `build/2`: it fetches the
      `type:task` corpus GLOBALLY for a dataset (no fail-closed workspace
      scope — a nil-workspace `Queue.ready/1` would `where: false` → silently
      empty; charter decision D3), attaches each card's blocker statuses, its
      criteria progress, and its `content.github` mirror, then calls `build/2`.

  ## The `ready` overlay (charter D3)

  There is no stored `ready` lifecycle status — it is a GRAPH property computed
  in-memory from the fetched corpus: a card is `ready` when its
  `lifecycle_status ∈ {open, blocked}` AND every outbound `blocks`-edge target
  is `done`. `open` with no blockers is vacuously ready. Ready is never a drop
  target (a drag can't satisfy a dependency graph) — that is a later wave's
  concern; this module only derives it.

  ## The normalized card

  The loader projects each `%Document{}` into:

      %{doc_id, title, priority, parent_id, labels, worker, lifecycle_status,
        criteria: %{met, total} | nil, github: map | nil, github_synced: boolean,
        blocker_statuses: [String.t()], updated_at}

  and `build/2` enriches each with a `:col` (its bucket), a `:glyph`, and a
  `:color_role` per the §1 shared white-ladder vocabulary
  (`.claude/workflows/bp-task-design-language-spec.md`).
  """

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.Link
  alias Barkpark.Repo
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Edge

  @columns [:open, :ready, :in_progress, :blocked, :done]

  @typedoc "A normalized-then-enriched card as it leaves `build/2`."
  @type card :: %{
          doc_id: String.t(),
          title: String.t() | nil,
          priority: term(),
          parent_id: String.t() | nil,
          labels: [String.t()],
          worker: String.t() | nil,
          lifecycle_status: String.t(),
          criteria: %{met: non_neg_integer(), total: pos_integer()} | nil,
          github: map() | nil,
          github_synced: boolean(),
          blocker_statuses: [String.t()],
          updated_at: DateTime.t() | nil,
          col: atom(),
          glyph: String.t(),
          color_role: atom()
        }

  @type board :: %{
          columns: %{required(atom()) => [card()]},
          cancelled_count: non_neg_integer(),
          momentum: %{
            in_flight: non_neg_integer(),
            ready: non_neg_integer(),
            done_today: non_neg_integer(),
            pct: non_neg_integer()
          },
          cards_by_id: %{optional(String.t()) => card()}
        }

  @doc "The status-ladder columns, in render order: open · ready · in_progress · blocked · done."
  @spec columns() :: [atom()]
  def columns, do: @columns

  # ── snapshot/1 — the impure loader ─────────────────────────────────────────

  @doc """
  Load the live board for a dataset (default `"production"`).

  Reads the `type:task` corpus GLOBALLY (no workspace fail-closed scope), dedups
  draft/published twins to one card per logical id, attaches each card's blocker
  statuses (the `lifecycle_status` of every outbound `blocks`-edge target),
  criteria progress, and `content.github` mirror, then folds it through the pure
  `build/2`. `opts[:now]` is injected for testability; it defaults to
  `DateTime.utc_now/0`.
  """
  @spec snapshot(keyword()) :: board()
  def snapshot(opts \\ []) do
    dataset = Keyword.get(opts, :dataset, "production")
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    docs = load_task_docs(dataset)
    status_by_pk = Map.new(docs, fn d -> {d.id, lifecycle_of(d)} end)
    blockers_by_pk = load_blocker_targets(Map.keys(status_by_pk))

    docs
    |> Enum.map(&to_card(&1, blockers_by_pk, status_by_pk))
    |> build(now: now)
  end

  # Fetch every task doc for the dataset, then collapse each logical id's
  # draft/published twins to a single canonical card (published wins). The board
  # is a supervisor read — it shows one card per task, not the draft shadow the
  # github-bookkeeping stamp can leave behind.
  defp load_task_docs(dataset) do
    from(d in Document, where: d.type == "task" and d.dataset == ^dataset)
    |> Repo.all()
    |> Enum.group_by(fn d -> Content.published_id(d.doc_id) end)
    |> Enum.map(fn {_lid, twins} -> canonical_twin(twins) end)
  end

  defp canonical_twin(twins) do
    Enum.find(twins, hd(twins), fn d -> d.status == "published" end)
  end

  # One batched query for every outbound `blocks` edge in the corpus, grouped
  # `from_pk => [to_pk]`. Charter allows batched OR per-task; batched keeps the
  # board O(1) queries regardless of corpus size.
  defp load_blocker_targets([]), do: %{}

  defp load_blocker_targets(pks) do
    from(e in Edge, where: e.from_id in ^pks and e.kind == "blocks", select: {e.from_id, e.to_id})
    |> Repo.all()
    |> Enum.group_by(fn {from, _to} -> from end, fn {_from, to} -> to end)
  end

  defp to_card(doc, blockers_by_pk, status_by_pk) do
    content = doc.content || %{}

    blocker_statuses =
      blockers_by_pk
      |> Map.get(doc.id, [])
      |> Enum.map(fn to_pk -> Map.get(status_by_pk, to_pk, "unknown") end)

    %{
      doc_id: Content.published_id(doc.doc_id),
      title: doc.title,
      priority: Map.get(content, "priority"),
      parent_id: Map.get(content, "parent_id"),
      labels: normalize_labels(Map.get(content, "labels")),
      worker: Map.get(content, "assignee") || get_in(content, ["claim", "worker"]),
      lifecycle_status: lifecycle_of(doc),
      criteria: Tasks.criteria_progress(content),
      github: Link.get(doc),
      github_synced: Link.synced?(doc),
      blocker_statuses: blocker_statuses,
      updated_at: doc.updated_at
    }
  end

  defp normalize_labels(labels) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp normalize_labels(_), do: []

  defp lifecycle_of(%Document{content: content}),
    do: Map.get(content || %{}, "lifecycle_status") || "open"

  # ── build/2 — the pure organizer ───────────────────────────────────────────

  @doc """
  Fold a list of normalized cards into the board projection. PURE.

  Returns `%{columns, cancelled_count, momentum, cards_by_id}`. `opts[:now]` (a
  `DateTime`) dates the `done_today` tally; it defaults to `DateTime.utc_now/0`
  but callers inject it for determinism.
  """
  @spec build([map()], keyword()) :: board()
  def build(cards, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    {cancelled, live} = Enum.split_with(cards, &(&1.lifecycle_status == "cancelled"))

    enriched =
      Enum.map(live, fn card ->
        col = bucket(card)
        Map.merge(card, %{col: col, glyph: glyph_for(col), color_role: col})
      end)

    by_col = Enum.group_by(enriched, & &1.col)
    columns = Map.new(@columns, fn col -> {col, order(col, Map.get(by_col, col, []))} end)

    total_non_cancelled = length(enriched)
    done = Map.get(columns, :done, [])

    momentum = %{
      in_flight: length(Map.get(columns, :in_progress, [])),
      ready: length(Map.get(columns, :ready, [])),
      done_today: Enum.count(done, &same_utc_day?(&1.updated_at, now)),
      pct: round(length(done) / max(total_non_cancelled, 1) * 100)
    }

    %{
      columns: columns,
      cancelled_count: length(cancelled),
      momentum: momentum,
      cards_by_id: Map.new(enriched, fn c -> {c.doc_id, c} end)
    }
  end

  # Bucketing (charter): in_progress/done are stored states; ready is the
  # derived overlay; open/blocked are the fall-through.
  defp bucket(%{lifecycle_status: "in_progress"}), do: :in_progress
  defp bucket(%{lifecycle_status: "done"}), do: :done

  defp bucket(card) do
    cond do
      ready?(card) -> :ready
      card.lifecycle_status == "blocked" -> :blocked
      true -> :open
    end
  end

  # A card is ready when it is open|blocked AND all its `blocks` targets are
  # done. An empty blocker list is vacuously ready (open with no deps).
  defp ready?(%{lifecycle_status: s, blocker_statuses: bs}) when s in ["open", "blocked"],
    do: Enum.all?(bs, &(&1 == "done"))

  defp ready?(_), do: false

  # Ready sorts by priority (asc, nulls last) then most-recently-touched; every
  # other column is most-recently-touched first. Done recedes visually (dim) but
  # stays in updated_at order so a fresh completion sits at the top of the pile.
  defp order(:ready, cards) do
    Enum.sort_by(cards, fn c -> {priority_key(c.priority), -dt_unix(c.updated_at)} end)
  end

  defp order(_col, cards), do: Enum.sort_by(cards, &dt_unix(&1.updated_at), :desc)

  defp priority_key(p) when is_integer(p), do: {0, p}
  defp priority_key(p) when is_binary(p), do: {0, priority_from_string(p)}
  defp priority_key(_), do: {1, 0}

  defp priority_from_string(p) do
    case Integer.parse(p) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp dt_unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp dt_unix(_), do: 0

  defp same_utc_day?(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.to_date(a) == DateTime.to_date(b)

  defp same_utc_day?(_, _), do: false

  # §1 white-ladder glyphs — the IDENTICAL Unicode the TUI paints, never an SVG.
  # open/ready share `○` (opacity is the only difference, applied in CSS by
  # color_role); in_progress is the Braille spinner (base frame here — the live
  # frame-cycle is a pure-CSS `::before` animation in the render).
  defp glyph_for(:open), do: "○"
  defp glyph_for(:ready), do: "○"
  defp glyph_for(:in_progress), do: "⠋"
  defp glyph_for(:blocked), do: "!"
  defp glyph_for(:done), do: "✓"
end
