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
        blocker_statuses: [String.t()], sub, next_criterion, updated_at}

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
  alias Barkpark.Tasks.Validation

  # The status ladder in render order. The five WORK columns come first; the two
  # THOUGHT columns (TLV charter D11/D14) sit at the LADDER BOTTOM — a task being
  # weighed (`considering`) or actively researched (`researching`) is VISIBLE and
  # dim, out of the work funnel's way. Placement and meaning are DECOUPLED here:
  # a column says WHERE a card sits, `color_role/2` says WHAT it is (see
  # `enrich/1`), so a fall-through placement can never assert a bright work state.
  @columns [:open, :ready, :in_progress, :blocked, :done, :considering, :researching]

  # Derived at compile time from the ONE claimability source of truth
  # (Validation.claimable_statuses/0 — ~w(open blocked)); never fork a local
  # literal. Keeps the `ready?/1` overlay guard in lockstep with the ready-queue
  # allowlist (Tasks.Queue) and the targeted-claim guard (Tasks.Claim).
  @claimable_statuses Validation.claimable_statuses()

  # The done column is WINDOWED (charter D10) so the board never becomes a dead
  # wall of finished work (§0). `build/2` + `apply_change/3` render only the most
  # recent @done_window done cards (newest-first); `momentum.pct`/`done_today`
  # and `done_total` are always computed from the FULL done set BEFORE this cap
  # so the maths stay honest. 12 mirrors the TUI FocusSet neighbourhood cap.
  @done_window 12

  # §1 white-ladder glyphs — the SINGLE SOURCE OF TRUTH (charter D17). The GUI
  # board (`glyph_for/1` → the render) and the TUI (`internal/taskboard/
  # components.go` `StatusGlyph`) both paint the IDENTICAL Unicode character,
  # never a lookalike SVG. This map is the GUI's owner; the codepoint-parity
  # test (`board_theme_parity_test.exs`) asserts it EQUALS the Go table so the
  # twin surfaces can't drift. It carries `cancelled: "✕"` for SHARED-TRUTH
  # parity even though the board FOLDS cancelled to a tally (the glyph is
  # shared; its placement isn't — D17).
  # `considering` ◌ (U+25CC DOTTED CIRCLE) and `researching` ◎ (U+25CE BULLSEYE)
  # mirror the GENERATED lifecycle manifest (design/tokens.json → tokens_gen.go /
  # BarkparkWeb.Studio.TokensGen) added by tlv-s2 — never hand-picked here.
  #
  # `unknown` is the GUI's own fail-open mark: it is NOT a stored lifecycle state
  # and has no TUI twin, so it is deliberately absent from the parity gate's
  # shared-key list. It exists so `glyph_for/1` can be TOTAL — a lifecycle value
  # this build has never heard of paints a neutral dot instead of raising.
  @glyphs %{
    open: "○",
    ready: "○",
    in_progress: "⠋",
    blocked: "!",
    done: "✓",
    cancelled: "✕",
    considering: "◌",
    researching: "◎",
    unknown: "·"
  }

  # ── col ≠ color_role (TLV charter D14) ──────────────────────────────────────
  #
  # `col` is PLACEMENT and `color_role` is MEANING, and they are resolved by two
  # different functions. `bucket/1`'s cond falls through to `:open` so a card is
  # never DROPPED, but that fall-through must not also paint the card as ordinary
  # backlog — it used to (`color_role: col`), which made an unrecognised
  # lifecycle value look like a claimable open task. This map is the explicit
  # status → role read; anything absent from it is `:unknown` (dim neutral).
  @color_roles %{
    "open" => :open,
    "in_progress" => :in_progress,
    "blocked" => :blocked,
    "done" => :done,
    "cancelled" => :cancelled,
    "considering" => :considering,
    "researching" => :researching
  }

  # The fail-open role: visible, neutral, dim — never a work state.
  @unknown_role :unknown

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
          sub: %{total: pos_integer(), done: non_neg_integer(), active: map() | nil} | nil,
          next_criterion: String.t() | nil,
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

  @doc """
  The status-ladder columns, in render order: the five work columns
  (open · ready · in_progress · blocked · done) then the two THOUGHT columns
  (considering · researching) at the ladder bottom.
  """
  @spec columns() :: [atom()]
  def columns, do: @columns

  @doc """
  The §1 white-ladder glyph map — the SINGLE SOURCE OF TRUTH for the GUI board,
  asserted codepoint-equal to the TUI's `StatusGlyph` table by the parity gate
  (charter D17) for every SHARED lifecycle key: open ○ · ready ○ · in_progress ⠋
  · blocked ! · done ✓ · cancelled ✕ · considering ◌ · researching ◎. Carries
  `cancelled` for shared truth even though the board folds it to a tally, plus
  the GUI-only `unknown: "·"` fail-open mark, which is not a lifecycle state and
  has no TUI twin.
  """
  @spec glyphs() :: %{atom() => String.t()}
  def glyphs, do: @glyphs

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
    readable? = field_visibility_gate(dataset)

    docs
    |> Enum.map(&to_card(&1, blockers_by_pk, status_by_pk, readable?))
    |> build(now: now)
  end

  @doc """
  Field-visibility seal (felix W18/W19) — resolve the `task` schema ONCE for a
  dataset (NOT per card) and return a fail-closed visibility predicate
  `(field :: String.t()) -> boolean()`.

  This mirrors board_live's peek seal (load_peek/peek_schema/peek_field_readable?,
  merged #5470) and `tasks/query.ex` measure_field_readable?/2: an ANONYMOUS
  caller, so any content field the schema declares private / owner_only /
  readable_by is redacted from the card projection — and therefore from every
  derived copy (`family_walk/4` rows, `gantt_data/1`, `focus_of/1`) which read
  the gated card fields, never the raw doc. A nil schema (miss) leaves every
  field undeclared ⇒ public (legacy parity), never a crash. One indexed
  `Content.get_schema/3` bounds the cost.

  PUBLIC (felix W19): the realtime path (`board_live` mount + `:refresh`)
  computes the predicate ONCE per mount/reconcile and threads it into
  `card_from_broadcast/3`, so a broadcast card is gated by the same decisions as
  a fetched `to_card/4` one — WITHOUT resolving the schema per broadcast.
  """
  @spec field_visibility_gate(String.t()) :: (String.t() -> boolean())
  def field_visibility_gate(dataset) do
    schema =
      case Content.get_schema("task", dataset, []) do
        {:ok, schema} -> schema
        _ -> nil
      end

    fn field ->
      Barkpark.Content.Envelope.field_readable?(
        schema,
        field,
        Barkpark.Content.CallerContext.anonymous()
      )
    end
  end

  # The board's SAFETY CAP (felix W25) — a NAMED failure-mode fix: the bounded
  # HTTP task reader (`tasks/query.ex`, which clamps at 500/1000 via `clamp_limit`)
  # had an UNBOUNDED LiveView twin here. `load_task_docs/1` is re-run every 15s
  # PER connected Studio board socket (`board_live.ex` @refresh_ms), so an
  # unbounded `Repo.all` over the whole `type:task` corpus is a load amplifier
  # that grows with the corpus. This attribute caps the scan well above today's
  # ~6k-doc corpus (query.ex's 1000 clamp would truncate a real board, so the
  # HTTP limit is NOT reusable as the board bound) and is config-overridable so
  # ops can retune without a redeploy and tests can shrink it.
  #
  # This is a SAFETY CAP, not pagination: twin collapse (below) happens in Elixir
  # AFTER `Repo.all`, so the cap bounds the ROW scan, not the card count — it is
  # deliberately NOT query.ex's SQL `collapse_twins` (different collapse
  # semantics = a behavior change, out of scope for this improvement-only slice).
  @snapshot_max 10_000
  defp snapshot_max, do: Application.get_env(:barkpark, :board_snapshot_max, @snapshot_max)

  # Fetch every task doc for the dataset (up to the safety cap above), then
  # collapse each logical id's draft/published twins to a single canonical card
  # (published wins). The board is a supervisor read — it shows one card per
  # task, not the draft shadow the github-bookkeeping stamp can leave behind.
  defp load_task_docs(dataset) do
    from(d in Document,
      where: d.type == "task" and d.dataset == ^dataset,
      limit: ^snapshot_max()
    )
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

  # Project one fetched task doc into a normalized card. `readable?` is the
  # snapshot-wide fail-closed field-visibility predicate (`field_visibility_gate/1`):
  # THE single seal point (charter W18). Every private-capable content field is
  # gated here so the deck card AND every derived copy — `family_walk/4`'s tree
  # rows, `gantt_data/1`'s root row, `focus_of/1`'s focus line — inherit the
  # redaction from the card fields (they never re-read the raw doc). Gating at
  # the render sites instead would let the two derived copies diverge, so the
  # gate lives HERE. The text-bearing fields (description_excerpt, design_doc,
  # criteria_list, next_criterion — the last two BOTH read raw acceptance_criteria
  # text) plus the peek-parity fields (labels, priority, parent_id, worker) are
  # gated; the derived criteria COUNT (`Tasks.criteria_progress/1`, a pure
  # %{met,total} tally that never carries criterion text) stays UNGATED per the
  # peek's own count-vs-text law.
  defp to_card(doc, blockers_by_pk, status_by_pk, readable?) do
    content = doc.content || %{}

    blocker_statuses =
      blockers_by_pk
      |> Map.get(doc.id, [])
      |> Enum.map(fn to_pk -> Map.get(status_by_pk, to_pk, "unknown") end)

    %{
      doc_id: Content.published_id(doc.doc_id),
      title: doc.title,
      priority: if(readable?.("priority"), do: Map.get(content, "priority")),
      parent_id: if(readable?.("parent_id"), do: Map.get(content, "parent_id")),
      labels:
        if(readable?.("labels"), do: normalize_labels(Map.get(content, "labels")), else: []),
      # worker is drawn from `assignee` OR the nested `claim.worker`; redact it
      # unless BOTH sources are readable (fail-closed union — a private claim
      # must not leak its worker through the assignee-shaped field, and vice
      # versa).
      worker: gated_worker(content, readable?),
      lifecycle_status: lifecycle_of(doc),
      criteria: Tasks.criteria_progress(content),
      github: Link.get(doc),
      github_synced: Link.synced?(doc),
      blocker_statuses: blocker_statuses,
      next_criterion: if(readable?.("acceptance_criteria"), do: next_criterion(content)),
      description_excerpt:
        if(readable?.("description"), do: excerpt(Map.get(content, "description"))),
      design_doc:
        if(readable?.("design_doc"), do: string_presence(Map.get(content, "design_doc"))),
      criteria_list: if(readable?.("acceptance_criteria"), do: criteria_list(content)),
      created_at: doc.inserted_at,
      updated_at: doc.updated_at
    }
  end

  defp gated_worker(content, readable?) do
    if readable?.("assignee") and readable?.("claim") do
      Map.get(content, "assignee") || get_in(content, ["claim", "worker"])
    end
  end

  # The card-sized criteria CHECKLIST — text + met only (evidence stays in the
  # peek), capped at projection so a criteria-heavy task never fattens
  # cards_by_id. nil when the task has none.
  @criteria_list_cap 8
  defp criteria_list(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) and list != [] ->
        list
        |> Enum.take(@criteria_list_cap)
        |> Enum.with_index(1)
        |> Enum.map(fn
          {%{} = entry, i} ->
            %{
              text: string_presence(entry["criterion"]) || "criterion #{i}",
              met: entry["met"] == true
            }

          {_other, i} ->
            %{text: "criterion #{i}", met: false}
        end)

      _ ->
        nil
    end
  end

  # The card-sized slice of a task's markdown description — enough to READ on
  # the board (the peek carries the full text; a linked design_doc paper
  # carries the PortableDoc-rich version). Blank → nil, never "".
  @excerpt_chars 420
  defp excerpt(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @excerpt_chars)
    end
  end

  defp excerpt(_), do: nil

  defp string_presence(v) when is_binary(v) and v != "", do: v
  defp string_presence(_), do: nil

  # The first unmet acceptance criterion's text — the current STEP inside a
  # task with no in-flight subtask (the board's focus line falls back to it).
  # An unmet entry with no usable text is skipped rather than blanking the
  # focus; no criteria (or all met) is nil, never "".
  defp next_criterion(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) ->
        Enum.find_value(list, fn
          %{"met" => true} ->
            nil

          %{} = entry ->
            case Map.get(entry, "criterion") do
              text when is_binary(text) and text != "" -> text
              _ -> nil
            end

          _ ->
            nil
        end)

      _ ->
        nil
    end
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
    enriched = live |> Enum.map(&enrich/1) |> attach_subtasks()

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
  #
  # THE DECOUPLE (TLV charter D14): the column is `bucket/1`'s placement, the
  # role is `color_role/2`'s explicit status read, and the GLYPH follows the ROLE
  # (what the card IS), not the column (where it happens to sit). So an
  # unrecognised lifecycle value lands in `:open` — visible, never dropped — while
  # painting the dim `:unknown` neutral dot rather than a bright backlog ○.
  defp enrich(card) do
    col = bucket(card)
    role = color_role(col, card)
    Map.merge(card, %{col: col, glyph: glyph_for(role), color_role: role})
  end

  # `:ready` is the one DERIVED role — an open/blocked card whose blockers are all
  # done is genuinely claimable, and that overlay is exactly what the bright ○
  # reports, so the column wins there. Every other role is read from the card's
  # own stored `lifecycle_status`, with `@unknown_role` for anything unmapped.
  defp color_role(:ready, _card), do: :ready

  defp color_role(_col, card),
    do: Map.get(@color_roles, card.lifecycle_status, @unknown_role)

  # Subtask lineage (wave 12) — a card whose doc_id other live cards name as
  # their `parent_id` carries a `:sub` summary: how many children, how many
  # done, and the ONE in-flight child (title + worker) — the TUI's
  # activity-focus read, "what is being worked right now inside this task".
  # Cancelled children never count (they were split out before enrich);
  # childless cards carry nil. Derived at build time from the same corpus —
  # a realtime event refreshes it on the next :refresh reconcile.
  defp attach_subtasks(cards) do
    by_parent =
      cards
      |> Enum.filter(&is_binary(&1.parent_id))
      |> Enum.group_by(& &1.parent_id)

    Enum.map(cards, fn card ->
      Map.put(card, :sub, sub_summary(Map.get(by_parent, card.doc_id, [])))
    end)
  end

  defp sub_summary([]), do: nil

  defp sub_summary(children) do
    active = Enum.find(children, &(&1.lifecycle_status == "in_progress"))

    %{
      total: length(children),
      done: Enum.count(children, &(&1.lifecycle_status == "done")),
      active: active && %{title: active.title, worker: active.worker}
    }
  end

  # Group + order enriched live cards into the render columns, capping the
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
  Project a broadcast `doc` map into a normalized card, applying the same
  fail-closed field-visibility gate as `to_card/4`. PURE, DB-free.

  The broadcast (`Content.Broadcast`) carries only `%{doc_id, title, status,
  content, updated_at}` for the ONE changed doc — never the dependency graph. So
  this is byte-parallel to `snapshot`'s private `to_card/4` with two differences:
  it **carries `prev_card.blocker_statuses`/`:sub`/`:created_at` forward** (the
  event has none) so an already-known card keeps its readiness inputs, and it
  takes the visibility predicate `readable?` INJECTED by the caller instead of
  resolving the schema itself.

  FIELD-VISIBILITY SEAL (felix W19). `readable?` is `field_visibility_gate/1`'s
  fail-closed predicate, computed ONCE per mount/`:refresh` by `board_live` and
  threaded in — NEVER resolved per broadcast (no DB on the hot event path). It
  gates EXACTLY the 7 text/PII fields `to_card/4` gates — priority, parent_id,
  labels (else `[]`), worker (via `gated_worker/2`, the assignee⊕claim union),
  next_criterion + criteria_list (both under `"acceptance_criteria"`),
  description_excerpt (under `"description"`), design_doc. `lifecycle_status`,
  `github`, `github_synced` and the carried-forward `blocker_statuses` STAY
  UNGATED — parity with BOTH sealed paths (#5470 peek + #5779 snapshot); the
  derived criteria COUNT stays ungated per the peek's count-vs-text law. On the
  disconnected mount `board_live` injects `fn _ -> false end` (fail-closed), but
  no broadcast can arrive pre-connect, so behavior is identical.

  `Content.published_id/1` collapses the draft/published twin to the same logical
  id `snapshot` keys on, so a draft-shadow event updates the one canonical card.
  """
  @spec card_from_broadcast(map(), card() | nil, (String.t() -> boolean())) :: map()
  def card_from_broadcast(msg_doc, prev_card, readable?) when is_function(readable?, 1) do
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
      priority: if(readable?.("priority"), do: Map.get(content, "priority")),
      parent_id: if(readable?.("parent_id"), do: Map.get(content, "parent_id")),
      labels:
        if(readable?.("labels"), do: normalize_labels(Map.get(content, "labels")), else: []),
      worker: gated_worker(content, readable?),
      lifecycle_status: Map.get(content, "lifecycle_status") || "open",
      criteria: Tasks.criteria_progress(content),
      github: Link.get(synthetic),
      github_synced: Link.synced?(synthetic),
      blocker_statuses: (prev_card && prev_card.blocker_statuses) || [],
      # The event names no children; carry the previous projection's sub
      # summary forward (like blocker_statuses) — the slow :refresh reconcile
      # re-derives it from the full corpus.
      sub: (prev_card && prev_card[:sub]) || nil,
      next_criterion: if(readable?.("acceptance_criteria"), do: next_criterion(content)),
      description_excerpt:
        if(readable?.("description"), do: excerpt(Map.get(content, "description"))),
      design_doc:
        if(readable?.("design_doc"), do: string_presence(Map.get(content, "design_doc"))),
      criteria_list: if(readable?.("acceptance_criteria"), do: criteria_list(content)),
      # The broadcast carries no inserted_at — keep the previous projection's
      # creation stamp (the :refresh reconcile re-reads it).
      created_at: prev_card && prev_card[:created_at],
      updated_at: msg_doc.updated_at
    }
  end

  @doc """
  Re-bucket ONE card into an existing board and report the delta. PURE.

  `card` is a normalized card (typically from `card_from_broadcast/3`). Returns
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

  # Dropping your own in-flight card back on Open is a voluntary UNCLAIM
  # (wave 17): the fenced release primitive — never a raw reopen.
  def restage_plan(:in_progress, :open, holder, worker) when holder == worker,
    do: {:release}

  def restage_plan(_from, _to, _holder, _worker), do: :refuse

  # ── wave 4: group-by + filter (charter D13/D14/D15) ────────────────────────
  #
  # A big board stays LEGIBLE and FOCUSED by FOLDING the ALREADY-FETCHED
  # `cards_by_id` (the DB read already happened at snapshot/refresh — D3) through
  # a few more PURE functions: `facets/1` enumerates the chip menu, `card_matches?/2`
  # is the filter predicate, and `view/2` partitions the filtered corpus into
  # swimlanes — each lane run through the SAME private `organize/1` the flat board
  # uses (so `@done_window` caps EACH lane's done sub-column, D10 per-lane). NO
  # re-query: this is a projection over the snapshot the LiveView already holds.

  @group_keys [:none, :goal, :priority, :label]
  @facet_keys [:goal, :priority, :label, :worker]

  @doc "The swimlane group-by keys the chip menu offers: none · goal · priority · label."
  @spec group_keys() :: [atom()]
  def group_keys, do: @group_keys

  @typedoc "The chip-menu facets present in the board (only values that actually exist)."
  @type facets :: %{
          goals: [String.t()],
          priorities: [String.t()],
          labels: [String.t()],
          workers: [String.t()]
        }

  @doc """
  The DISTINCT, sorted facet values present in the board's `cards_by_id`. PURE.

  So the chip menu offers ONLY facets that exist: goals from `parent_id`,
  priorities from `priority` (as strings, numeric-sorted), labels flattened from
  every card's label list, workers from `worker`. Nils/blanks are dropped.
  """
  @spec facets(board()) :: facets()
  def facets(board) do
    cards = Map.values(board.cards_by_id)

    %{
      goals: cards |> Enum.map(& &1.parent_id) |> distinct_sorted(),
      priorities:
        cards |> Enum.map(&priority_string(&1.priority)) |> distinct_sorted_priorities(),
      labels: cards |> Enum.flat_map(& &1.labels) |> distinct_sorted(),
      workers: cards |> Enum.map(& &1.worker) |> distinct_sorted()
    }
  end

  @doc """
  Does a card satisfy the active filters? PURE.

  `filters = %{goal: [str], priority: [str], label: [str], worker: [str]}`. A `[]`
  (or missing) facet is UNCONSTRAINED; the facets AND together; WITHIN a facet the
  card's value(s) need only intersect the requested set (so the label facet passes
  when the card's label set intersects the requested labels).
  """
  @spec card_matches?(map(), map()) :: boolean()
  def card_matches?(card, filters) do
    facet_match?(filters[:goal], [card.parent_id]) and
      facet_match?(filters[:priority], [priority_string(card.priority)]) and
      facet_match?(filters[:label], card.labels) and
      facet_match?(filters[:worker], [card.worker])
  end

  # A nil/[] request is unconstrained; otherwise at least one non-nil card value
  # must be in the requested set (set intersection).
  defp facet_match?(nil, _card_values), do: true
  defp facet_match?([], _card_values), do: true

  defp facet_match?(requested, card_values) when is_list(requested),
    do: Enum.any?(card_values, fn v -> not is_nil(v) and v in requested end)

  @typedoc "One swimlane in a `view/2`: its columns + counts, run through `organize/1`."
  @type lane :: %{
          key: atom() | String.t() | nil,
          label: String.t() | nil,
          columns: %{required(atom()) => [card()]},
          counts: %{required(atom()) => non_neg_integer()},
          done_total: non_neg_integer()
        }

  @typedoc "The filtered-and-grouped projection the LiveView renders."
  @type view :: %{
          lanes: [lane()],
          momentum: map(),
          facets: facets(),
          filtered?: boolean(),
          grouped?: boolean(),
          family?: boolean(),
          empty?: boolean()
        }

  @doc """
  Fold an already-built board into a filtered-and-grouped VIEW. PURE.

  `opts`: `group_by: :none | :goal | :priority | :label` (default `:none`),
  `filters: %{...}` (see `card_matches?/2`, default `%{}`), `now: DateTime` (dates
  a narrowed `done_today`, default `DateTime.utc_now/0`).

  It (1) filters `cards_by_id` by `card_matches?/2`, (2) partitions the survivors
  by `group_by` (a `nil`/none lane holds cards with no value for the key; the
  label facet is multi-valued so a card can appear in several lanes), and (3) runs
  each lane through the SAME private `organize/1` — so `@done_window` caps EACH
  lane's done sub-column and every lane carries per-column counts + a full
  `done_total`.

  `group_by == :none` with NO filters is the FAMILY view (wave 16): tasks whose
  parent is on the board fold INTO their root's card (`family_fold/1`) — fewer,
  larger cards, no duplication; grouped/filtered views stay per-task (the
  drill-down).

  MOMENTUM HONESTY (D13): `momentum` is `board.momentum` UNCHANGED whenever the
  filters are empty (grouping alone never moves the numbers — it preserves wave-2's
  monotonic `done_today`). It is recomputed from the NARROWED columns only when a
  filter actually narrows the board.
  """
  @spec view(board(), keyword()) :: view()
  def view(board, opts \\ []) do
    group_by = normalize_group(Keyword.get(opts, :group_by, :none))
    filters = Keyword.get(opts, :filters, %{})
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    filtered? = any_filter?(filters)
    grouped? = group_by != :none
    facets = facets(board)

    if group_by == :none and not filtered? do
      # FAMILY view (wave 16) — the default board folds every task whose
      # parent is on the board INTO its root's card, so a family renders as
      # ONE larger card (fewer cards, no duplication) carrying its own
      # mini-tree. Momentum stays board.momentum — TASK-level, honest.
      {columns, family_done_total} = family_fold(board)

      lane = %{
        key: :all,
        label: nil,
        columns: columns,
        counts: lane_counts(columns, family_done_total),
        done_total: family_done_total
      }

      %{
        lanes: [lane],
        momentum: board.momentum,
        facets: facets,
        filtered?: false,
        grouped?: false,
        family?: true,
        empty?: board.cards_by_id == %{}
      }
    else
      filtered_cards =
        board.cards_by_id
        |> Map.values()
        |> Enum.filter(&card_matches?(&1, filters))

      momentum = if filtered?, do: narrowed_momentum(filtered_cards, now), else: board.momentum

      %{
        lanes: build_lanes(filtered_cards, group_by),
        momentum: momentum,
        facets: facets,
        filtered?: filtered?,
        grouped?: grouped?,
        family?: false,
        empty?: filtered_cards == []
      }
    end
  end

  # ── the family fold (wave 16) ───────────────────────────────────────────────
  #
  # ROOTS are cards whose parent is NOT on the board (nil parent_id or an
  # unknown/cancelled one — an orphan is its own root, never hidden). Each root
  # becomes one family card carrying `:family` — a depth-capped mini-tree of
  # its descendants (in-flight first) + whole-subtree stats — and is PLACED by
  # activity: a live root with ANY in-flight descendant escalates to the
  # in_progress column ("the epic is being worked"), else it sits in its own
  # bucket. The card's own glyph/color keep the root's true state, so an
  # escalated card reads "open epic, work in flight" at a glance. Grouped and
  # filtered views deliberately stay PER-TASK — they are the drill-down.
  # Mini-tree row order, most-active first. The thought columns rank BELOW the
  # work funnel and above done — a family row that is merely being weighed should
  # not outrank a blocked one. (`family_rank/1` still answers 99 for anything
  # unlisted, so the sort stays total.)
  @family_order [:in_progress, :ready, :open, :blocked, :researching, :considering, :done]
  @family_row_depth 3
  @family_row_cap 24

  defp family_fold(board) do
    cards = Map.values(board.cards_by_id)
    ids = board.cards_by_id

    index =
      cards
      |> Enum.filter(&is_binary(&1.parent_id))
      |> Enum.group_by(& &1.parent_id)

    family_cards =
      cards
      |> Enum.reject(fn c -> is_binary(c.parent_id) and Map.has_key?(ids, c.parent_id) end)
      |> Enum.map(fn root ->
        stats = family_stats(index, root.doc_id)
        {rows, more} = family_rows(index, root.doc_id)

        root
        |> Map.put(:col, family_col(root.col, stats))
        |> Map.put(:family, family_meta(rows, more, stats))
      end)

    {columns, done_full} = organize(family_cards)
    {columns, length(done_full)}
  end

  defp family_meta([], 0, _stats), do: nil
  defp family_meta(rows, more, stats), do: %{rows: rows, more: more, stats: stats}

  # Activity placement: a live (not done/cancelled) root with in-flight
  # descendants belongs where the work is.
  defp family_col(col, %{in_flight: n}) when n > 0 and col in [:open, :ready, :blocked],
    do: :in_progress

  defp family_col(col, _stats), do: col

  # Whole-subtree stats (every depth, cycle-safe): total, done, in-flight.
  defp family_stats(index, root_id) do
    descendants = family_descendants(index, [root_id], MapSet.new([root_id]), [])

    %{
      total: length(descendants),
      done: Enum.count(descendants, &(&1.col == :done)),
      in_flight: Enum.count(descendants, &(&1.col == :in_progress))
    }
  end

  defp family_descendants(_index, [], _seen, acc), do: acc

  defp family_descendants(index, [id | rest], seen, acc) do
    children =
      index
      |> Map.get(id, [])
      |> Enum.reject(fn c -> MapSet.member?(seen, c.doc_id) end)

    seen = Enum.reduce(children, seen, fn c, s -> MapSet.put(s, c.doc_id) end)
    family_descendants(index, Enum.map(children, & &1.doc_id) ++ rest, seen, children ++ acc)
  end

  # The card's mini-tree rows: children + grandchildren (depth cap), in-flight
  # first at every level, capped to a handful — the peek's full tree carries
  # the rest, and the cap is an explicit "+N more" (never silent).
  defp family_rows(index, root_id) do
    rows = family_walk(index, root_id, 1, MapSet.new([root_id]))
    shown = Enum.take(rows, @family_row_cap)
    {shown, max(length(rows) - length(shown), 0)}
  end

  defp family_walk(_index, _id, depth, _seen) when depth > @family_row_depth, do: []

  defp family_walk(index, id, depth, seen) do
    index
    |> Map.get(id, [])
    |> Enum.reject(fn c -> MapSet.member?(seen, c.doc_id) end)
    |> Enum.sort_by(fn c -> {family_rank(c.col), c.title || c.doc_id} end)
    |> Enum.flat_map(fn c ->
      row = %{
        doc_id: c.doc_id,
        title: c.title,
        depth: depth,
        color_role: c.color_role,
        glyph: c.glyph,
        worker: c.worker,
        # The ONGOING task's text + criteria read on the card itself (waves
        # 19-20): only in-flight rows carry them — anything more is noise.
        desc: (c.col == :in_progress && c[:description_excerpt]) || nil,
        crits: (c.col == :in_progress && c[:criteria_list]) || nil,
        # Gantt fuel (wave 21): the bar runs created → (done ? closed : now).
        created_at: c[:created_at],
        updated_at: c.updated_at
      }

      [row | family_walk(index, c.doc_id, depth + 1, MapSet.put(seen, c.doc_id))]
    end)
  end

  defp family_rank(col), do: Enum.find_index(@family_order, &(&1 == col)) || 99

  defp normalize_group(g) when g in @group_keys, do: g
  defp normalize_group(_), do: :none

  defp any_filter?(filters) when is_map(filters) do
    Enum.any?(@facet_keys, fn key ->
      case Map.get(filters, key) do
        list when is_list(list) -> list != []
        _ -> false
      end
    end)
  end

  defp any_filter?(_), do: false

  # A single lane (group_by == :none, but filtered): the narrowed board as one
  # flat grid — no lane chrome (label nil).
  defp build_lanes(cards, :none) do
    {columns, done_full} = organize(cards)
    [lane_of(:all, nil, columns, done_full)]
  end

  # Grouped: partition into swimlanes, ordered, none-lane last, each organized.
  defp build_lanes(cards, group_by) do
    cards
    |> group_cards(group_by)
    |> Enum.map(fn {key, lane_cards} ->
      {columns, done_full} = organize(lane_cards)
      lane_of(key, lane_label(group_by, key), columns, done_full)
    end)
  end

  defp lane_of(key, label, columns, done_full) do
    %{
      key: key,
      label: label,
      columns: columns,
      counts: lane_counts(columns, length(done_full)),
      done_total: length(done_full)
    }
  end

  # Per-column counts; the done count is the FULL (pre-window) total (D10) so a
  # capped render never freezes the header.
  defp lane_counts(columns, done_total) do
    Map.new(@columns, fn
      :done -> {:done, done_total}
      col -> {col, length(Map.get(columns, col, []))}
    end)
  end

  # Single-valued grouping (goal/priority): every card lands in exactly one lane
  # (its value, or the nil none-lane). Multi-valued (label): a card appears in
  # each of its label lanes, or the none-lane when it has no labels.
  defp group_cards(cards, :goal),
    do: cards |> Enum.group_by(fn c -> lane_key(c.parent_id) end) |> sort_lanes(:goal)

  defp group_cards(cards, :priority),
    do:
      cards
      |> Enum.group_by(fn c -> lane_key(priority_string(c.priority)) end)
      |> sort_lanes(:priority)

  defp group_cards(cards, :label) do
    cards
    |> Enum.flat_map(fn c ->
      case c.labels do
        [] -> [{nil, c}]
        labels -> Enum.map(labels, fn l -> {l, c} end)
      end
    end)
    |> Enum.group_by(fn {k, _} -> k end, fn {_, c} -> c end)
    |> sort_lanes(:label)
  end

  defp lane_key(nil), do: nil
  defp lane_key(""), do: nil
  defp lane_key(v) when is_binary(v), do: v
  defp lane_key(v), do: to_string(v)

  # Non-none lanes sort ascending (priority numerically); the none-lane is always
  # last so "unassigned" work reads as the tail, not the head.
  defp sort_lanes(grouped, group_by) do
    grouped
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _cards} -> lane_sort_key(group_by, key) end)
  end

  defp lane_sort_key(_group_by, nil), do: {1, 0, ""}
  defp lane_sort_key(:priority, key), do: {0, priority_from_string(key), key}
  defp lane_sort_key(_group_by, key), do: {0, 0, key}

  defp lane_label(_group_by, nil), do: "none"
  defp lane_label(:goal, key), do: "↳" <> key
  defp lane_label(:priority, key), do: "P" <> key
  defp lane_label(:label, key), do: "#" <> key

  # A narrowed board's honest momentum (D13): in_flight/ready/pct/done_total from
  # the filtered columns, done_today from the filtered done cards vs the injected
  # `now`. Cancelled cards never live in `cards_by_id`, so the filtered set is the
  # non-cancelled denominator.
  defp narrowed_momentum(cards, now) do
    {columns, done_full} = organize(cards)

    %{
      in_flight: length(Map.get(columns, :in_progress, [])),
      ready: length(Map.get(columns, :ready, [])),
      done_today: Enum.count(done_full, &same_utc_day?(&1.updated_at, now)),
      pct: round(length(done_full) / max(length(cards), 1) * 100)
    }
  end

  defp priority_string(nil), do: nil
  defp priority_string(p) when is_integer(p), do: Integer.to_string(p)
  defp priority_string(p) when is_binary(p), do: p
  defp priority_string(p), do: to_string(p)

  defp distinct_sorted(values) do
    values
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp distinct_sorted_priorities(values) do
    values
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort_by(&priority_from_string/1)
  end

  # Bucketing (charter): in_progress/done and the two THOUGHT states are stored
  # states, matched by head clause BEFORE the cond; ready is the derived overlay;
  # open/blocked are the fall-through.
  #
  # The `true -> :open` fall-through means PLACEMENT ONLY — a card whose stored
  # status this build does not recognise still shows up (never dropped) but is
  # coloured by `color_role/2`, not by the column it landed in.
  defp bucket(%{lifecycle_status: "in_progress"}), do: :in_progress
  defp bucket(%{lifecycle_status: "done"}), do: :done
  defp bucket(%{lifecycle_status: "considering"}), do: :considering
  defp bucket(%{lifecycle_status: "researching"}), do: :researching

  defp bucket(card) do
    cond do
      ready?(card) -> :ready
      card.lifecycle_status == "blocked" -> :blocked
      true -> :open
    end
  end

  # A card is ready when it is open|blocked AND all its `blocks` targets are
  # done. An empty blocker list is vacuously ready (open with no deps).
  defp ready?(%{lifecycle_status: s, blocker_statuses: bs}) when s in @claimable_statuses,
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

  # §1 white-ladder glyphs — READ from the single-source `@glyphs` map (D17) so
  # the GUI can never drift from `Board.glyphs/0` / the TUI. open/ready share `○`
  # (opacity is the only difference, applied in CSS by color_role); in_progress
  # is the Braille spinner base frame (the live frame-cycle is a pure-CSS
  # `::before` animation in the render).
  #
  # TOTAL by construction: this used to be `Map.fetch!/2`, which RAISED on any
  # role the map had not heard of — the exact failure a fail-open surface must
  # not have. An unmapped role paints the neutral `unknown` dot.
  defp glyph_for(role), do: Map.get(@glyphs, role, @glyphs[@unknown_role])
end
