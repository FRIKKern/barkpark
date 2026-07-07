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

  # The done column is WINDOWED (charter D10) so the board never becomes a dead
  # wall of finished work (§0). `build/2` + `apply_change/3` render only the most
  # recent @done_window done cards (newest-first); `momentum.pct`/`done_today`
  # and `done_total` are always computed from the FULL done set BEFORE this cap
  # so the maths stay honest. 12 mirrors the TUI FocusSet neighbourhood cap.
  @done_window 12

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
          done_total: non_neg_integer(),
          cards_by_id: %{optional(String.t()) => card()}
        }

  @typedoc """
  The re-bucket delta `apply_change/3` returns for the LiveView to key its
  flash/slide off. `kind`:

    * `:moved`     — a known card changed column (e.g. open → in_progress)
    * `:closed`    — a known card reached `:done` (bumps `done_today`)
    * `:cancelled` — a known card left the columns to the cancelled tally
    * `:entered`   — a previously-unseen card appeared in a column
    * `:updated`   — a known card changed in place (same column)
    * `:ignored`   — a no-op (e.g. a cancelled event for an already-gone card)
  """
  @type change :: %{
          doc_id: String.t(),
          from_col: atom() | nil,
          to_col: atom(),
          kind: :moved | :closed | :cancelled | :entered | :updated | :ignored
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
    enriched = Enum.map(live, &enrich/1)

    {columns, done_full} = organize(enriched)

    momentum = %{
      in_flight: length(Map.get(columns, :in_progress, [])),
      ready: length(Map.get(columns, :ready, [])),
      # done_today + pct are computed from the FULL, uncapped done set (D10) so
      # the tally and bar never silently shrink when the column render caps.
      done_today: Enum.count(done_full, &same_utc_day?(&1.updated_at, now)),
      pct: round(length(done_full) / max(length(enriched), 1) * 100)
    }

    %{
      columns: columns,
      cancelled_count: length(cancelled),
      momentum: momentum,
      done_total: length(done_full),
      # cards_by_id is the FULL, uncapped live set (every column incl. all done)
      # — apply_change/3 treats it as the source of truth it re-buckets against,
      # so it must never carry the windowed done list.
      cards_by_id: Map.new(enriched, fn c -> {c.doc_id, c} end)
    }
  end

  # Enrich a normalized card with its bucket + §1 glyph/color_role.
  defp enrich(card) do
    col = bucket(card)
    Map.merge(card, %{col: col, glyph: glyph_for(col), color_role: col})
  end

  # Group + order enriched live cards into the five render columns, capping the
  # done column at @done_window (newest-first). Returns `{columns, done_full}`
  # where `done_full` is the UNCAPPED, ordered done list for honest momentum
  # maths (D10).
  defp organize(enriched) do
    by_col = Enum.group_by(enriched, & &1.col)
    ordered = Map.new(@columns, fn col -> {col, order(col, Map.get(by_col, col, []))} end)
    done_full = Map.get(ordered, :done, [])
    columns = Map.put(ordered, :done, Enum.take(done_full, @done_window))
    {columns, done_full}
  end

  # ── wave 2: realtime re-bucket (charter D9/D10) ────────────────────────────

  @doc """
  Project a broadcast `doc` map into a normalized card. PURE.

  The broadcast (`Content.Broadcast`) carries only `%{doc_id, title, status,
  content, updated_at}` for the ONE changed doc — never the dependency graph. So
  this is byte-parallel to `snapshot`'s private `to_card/3` with one difference:
  it **carries `prev_card.blocker_statuses` forward** (the event has none) so an
  already-known card keeps its readiness inputs. An unseen card gets `[]` and is
  placed by raw lifecycle (open/blocked/in_progress/done) — its `ready`
  correctness waits for the next `:refresh` reconcile (D9).

  `Content.published_id/1` collapses the draft/published twin to the same logical
  id `snapshot` keys on, so a draft-shadow event updates the one canonical card.
  """
  @spec card_from_broadcast(map(), card() | nil) :: map()
  def card_from_broadcast(msg_doc, prev_card) do
    content = msg_doc.content || %{}
    doc_id = Content.published_id(msg_doc.doc_id)

    # A synthesized Document fed to the SAME pure github reads snapshot uses, so
    # a broadcast card's github/github_synced projection matches a fetched one.
    synthetic = %Document{
      doc_id: doc_id,
      content: content,
      status: msg_doc.status,
      updated_at: msg_doc.updated_at
    }

    %{
      doc_id: doc_id,
      title: msg_doc.title,
      priority: Map.get(content, "priority"),
      parent_id: Map.get(content, "parent_id"),
      labels: normalize_labels(Map.get(content, "labels")),
      worker: Map.get(content, "assignee") || get_in(content, ["claim", "worker"]),
      lifecycle_status: Map.get(content, "lifecycle_status") || "open",
      criteria: Tasks.criteria_progress(content),
      github: Link.get(synthetic),
      github_synced: Link.synced?(synthetic),
      blocker_statuses: (prev_card && prev_card.blocker_statuses) || [],
      updated_at: msg_doc.updated_at
    }
  end

  @doc """
  Re-bucket ONE card into an existing board and report the delta. PURE.

  `card` is a normalized card (typically from `card_from_broadcast/2`). Returns
  `{board, change}` where `change` (see `t:change/0`) tells the LiveView which
  card moved and how, so it can flash/slide it.

  The board's `cards_by_id` is treated as the full, uncapped source of truth: we
  upsert (or, for a cancelled card, drop) the one card, re-derive every column +
  `momentum.{in_flight, ready, pct}` + `done_total` from it, and re-cap the done
  column at @done_window. `momentum.done_today` is **monotonic within a session**
  (D9): it bumps by exactly 1 on a genuine new close (`to_col == :done` and the
  card was not already `:done`) and is NEVER recomputed from the capped column —
  a `:refresh` snapshot resets it to the authoritative windowed value.
  """
  @spec apply_change(board(), map(), keyword()) :: {board(), change()}
  def apply_change(board, card, opts \\ []) do
    prev = Map.get(board.cards_by_id, card.doc_id)
    from_col = prev && prev.col

    if card.lifecycle_status == "cancelled" do
      apply_cancel(board, card, prev, from_col)
    else
      apply_live(board, card, prev, from_col, opts)
    end
  end

  # A cancelled card LEAVES the columns and bumps `cancelled_count` — but only
  # when it was actually present (an event for an already-gone/unseen cancelled
  # card is a no-op; :refresh owns the authoritative cancelled total).
  defp apply_cancel(board, card, nil, _from_col) do
    {board, %{doc_id: card.doc_id, from_col: nil, to_col: :cancelled, kind: :ignored}}
  end

  defp apply_cancel(board, card, _prev, from_col) do
    cards = Map.delete(board.cards_by_id, card.doc_id)
    new_board = reassemble(cards, board.cancelled_count + 1, board.momentum.done_today)
    {new_board, %{doc_id: card.doc_id, from_col: from_col, to_col: :cancelled, kind: :cancelled}}
  end

  # `opts` is accepted for signature symmetry with `build/2`/`snapshot/1`; a
  # re-bucket dates nothing (done_today is monotonic, not clock-derived), so no
  # `:now` is read here.
  defp apply_live(board, card, prev, from_col, _opts) do
    enriched = enrich(card)
    to_col = enriched.col

    fresh_close? = to_col == :done and from_col != :done

    kind =
      cond do
        is_nil(prev) -> :entered
        fresh_close? -> :closed
        to_col != from_col -> :moved
        true -> :updated
      end

    done_today = board.momentum.done_today + if(fresh_close?, do: 1, else: 0)
    cards = Map.put(board.cards_by_id, card.doc_id, enriched)
    new_board = reassemble(cards, board.cancelled_count, done_today)

    {new_board, %{doc_id: card.doc_id, from_col: from_col, to_col: to_col, kind: kind}}
  end

  # Rebuild the board projection from a (already-enriched) cards_by_id map. Every
  # column + in_flight/ready/pct/done_total is re-derived from the full uncapped
  # set (accurate); `done_today` is passed through UNCHANGED (monotonic, D9).
  defp reassemble(cards_by_id, cancelled_count, done_today) do
    enriched = Map.values(cards_by_id)
    {columns, done_full} = organize(enriched)
    total = map_size(cards_by_id)

    momentum = %{
      in_flight: length(Map.get(columns, :in_progress, [])),
      ready: length(Map.get(columns, :ready, [])),
      done_today: done_today,
      pct: round(length(done_full) / max(total, 1) * 100)
    }

    %{
      columns: columns,
      cancelled_count: cancelled_count,
      momentum: momentum,
      done_total: length(done_full),
      cards_by_id: cards_by_id
    }
  end

  # ── wave 3: drag restage (charter D4/D11) ──────────────────────────────────

  @typedoc """
  The fenced primitive a drop maps to (`restage_plan/4`):

    * `{:claim}`            — a claimable card enters `in_progress`
    * `{:close, "done"}`    — the holder closes their own card done
    * `{:close, "blocked"}` — the holder parks their own card blocked
    * `:refuse`             — no legal transition (snap the card back)
  """
  @type restage_plan :: {:claim} | {:close, String.t()} | :refuse

  @doc """
  The D11 transition table: which fenced primitive (if any) realizes a drag from
  `from_col` to `to_col`, given the task's true claim `holder` and the acting
  `worker`. PURE — no socket, no DB, no clock.

  The ONLY legal set:

    * `{open, ready, blocked} → in_progress` ⇒ `{:claim}` — the drop claims the
      task through `Tasks.claim_by_id/3` (which re-checks readiness + deps + the
      resource fence server-side; a foreign in-flight card naturally refuses
      there with `:not_ready`).
    * the holder's `in_progress → done` ⇒ `{:close, "done"}`.
    * the holder's `in_progress → blocked` ⇒ `{:close, "blocked"}`.

  EVERYTHING ELSE is `:refuse`:

    * a foreign hold (`holder != worker`) can never be closed — `close/3` fences
      on epoch, NOT identity, so a same-epoch close by a non-holder would corrupt
      the claim; refuse it BEFORE the primitive is ever called.
    * `→ open` (reopen) is deferred (D4); `→ ready` is a derived, non-drop column
      (D3); an unclaimed `→ done` and any `done → *` are not legal drags.
  """
  @spec restage_plan(atom(), atom(), String.t() | nil, String.t()) :: restage_plan()
  def restage_plan(from_col, to_col, holder, worker)

  def restage_plan(from, :in_progress, _holder, _worker)
      when from in [:open, :ready, :blocked],
      do: {:claim}

  def restage_plan(:in_progress, :done, holder, worker) when holder == worker,
    do: {:close, "done"}

  def restage_plan(:in_progress, :blocked, holder, worker) when holder == worker,
    do: {:close, "blocked"}

  def restage_plan(_from, _to, _holder, _worker), do: :refuse

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
