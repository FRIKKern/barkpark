defmodule Barkpark.Plugins.Tasks.Web.BoardLive do
  @moduledoc """
  Barkpark Projects — the native task BOARD, read-only baseline (wave 1).

  A visual kanban over the REAL `type:task` documents (the source of truth),
  mounted in Studio at `/admin/projects` (the `:ops` bucket, admin-gated). It is
  the GUI realization of the task design-language spec
  (`.claude/workflows/bp-task-design-language-spec.md`) — the browser sibling of
  the `bp tasks` TUI board — and clones the pulse `DashboardLive` shape: a
  standalone plugin LiveView, `/admin/*` (not `/studio/*`, which the desk-link
  scoper mangles), owned by the tasks plugin because it owns `type:task`.

  ## Feels-alive baseline (charter §criterion, wave 1)

  Even with NO realtime yet (subscribe/drag/refresh land in later waves), the
  board must FEEL ALIVE the instant it paints:

    * a **momentum header** — `◐ N in flight · ○ N ready · ✓ N done today · NN%`
      with an animated fill bar (CSS width transition) — is the always-on
      progress read;
    * the **Ready column** is the visible always-a-next-step;
    * the in_progress cards **breathe at rest** via a PURE-CSS Braille spinner
      (`@keyframes` cycling a `.gi--in_progress::before` through the 10 TUI
      frames ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ at ~80ms/frame) — zero JS, CSP-safe, and it works in a
      static render. `prefers-reduced-motion` freezes it on `⠿`.

  The glyph/color vocabulary is the §1 manifest VERBATIM — the identical Unicode
  character the TUI paints (never a lookalike SVG) — supplied by
  `Barkpark.Tasks.Board` (`glyph`/`color_role` per card) and dressed with the
  §1 light/dark hexes in the inline `<style>` block below.

  ## GitHub badge (charter D7)

  Each card whose `content.github` mirror is present (stamped by the just-shipped
  GitHub bridge) carries a badge — the mirror-issue `#number`, a sync dot
  (synced/detached), and a click-through to `github.com/<repo>/issues/<n>`. A
  card with no mirror renders NO badge — never fabricated. This is a pure
  `content.github` read attached in the organizer's card projection, safe even
  with the github plugin dark.

  ## Realtime motion (charter §criterion, wave 2)

  The board must not just paint alive — it must MOVE (§0: "you open the board and
  something is moving"). It rides the EXISTING task broadcast, no new process
  (charter D5): on `connected?/1`, `mount/3` subscribes to `documents:<dataset>`
  (the global per-dataset stream `Content.Broadcast` fires on every CAS write)
  and schedules a slow periodic `:refresh`. There is deliberately NO boot-started
  worker — subscription is per-socket only (the github-bridge CI landmine that
  breaks the full ExUnit sandbox).

  When a `{:document_changed, %{type: "task"}}` arrives, `Board.card_from_broadcast/2`
  projects the one changed doc, `Board.apply_change/3` re-buckets it (a LIGHT
  optimistic move, D9) and reports a `change` the render keys its flash/slide off
  (`data-just-moved` + a CSS `@keyframes`, CSP-safe). The done-today tally climbs
  monotonically and the momentum bar (already width-transitioned) grows — "you
  watch momentum". A slow `:refresh` full `Board.snapshot/1` reconcile (every 15s)
  silently corrects the derived `ready` overlay, cascade-unblocks, and the
  windowed `done_today` a single event cannot re-derive.

  A per-socket **seen-set** of `{doc_id, updated_at}` drops the mount-snapshot
  echo and exact-repeat events. Non-`task` events and anything else are ignored
  by a catch-all `handle_info` clause — a stray message never crashes the socket.

  ## Drag restage (charter §criterion, wave 3)

  The board is now INTERACTIVE. A card carries `draggable="true"`; the shared
  `BarkparkBoardDrag` hook (opt-in on `.bp-board`, CSP-safe, no bundler) pushes a
  `restage` event with the dragged card's `doc_id` and the target column's
  `data-col`. `handle_event/3` flips the task's lifecycle THROUGH THE SAME FENCED
  PRIMITIVES `bp` uses — never a raw `Content` write:

    * it resolves the Default-workspace scope (D12) and FRESH-reads the live task
      row for its uuid pk + observed epoch + true claim holder (never the board
      card's possibly-stale epoch);
    * the pure `Board.restage_plan/4` (D11) decides the primitive: a claimable
      card → `Tasks.claim_by_id/3`; the holder's in-flight card → `Tasks.close/3`
      (`done`/`blocked`); everything else refuses (a foreign hold, a `→ ready`
      non-drop (D3), a deferred reopen);
    * the move is OPTIMISTIC (D9) — the card re-buckets the instant you drop via
      the same `apply_change/3` the broadcast rides — and ROLLS BACK to a fresh
      `snapshot/1` with a dismissible notice if the fence refuses.

  No new process — the write rides THIS per-socket event (D5).
  """

  use BarkparkWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Repo
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Board
  alias Barkpark.Tenancy

  # The slow reconcile cadence. Realtime motion is instant off the broadcast;
  # this only re-derives what one event can't (ready overlay, cascade-unblocks,
  # the windowed done_today) — so seconds, not milliseconds, is right.
  @refresh_ms 15_000

  @dataset "production"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:dataset, @dataset)
     |> assign(:board, Board.snapshot(dataset: @dataset))
     |> assign(:last_change, nil)
     |> assign(:notice, nil)
     |> assign(:seen, MapSet.new())}
  end

  # A task mutation on our dataset stream — the live heartbeat of the board.
  # We only subscribe to `documents:#{@dataset}`, so every message here is for
  # the right dataset by construction (the broadcast carries no dataset field to
  # re-check; the topic IS the scope). Drop an exact-repeat/echo via the
  # seen-set, else project → re-bucket → flash.
  @impl true
  def handle_info({:document_changed, %{type: "task", doc: doc}}, socket)
      when is_map(doc) do
    key = {doc.doc_id, doc.updated_at}

    if MapSet.member?(socket.assigns.seen, key) do
      {:noreply, socket}
    else
      board = socket.assigns.board
      prev = board.cards_by_id[Content.published_id(doc.doc_id)]
      card = Board.card_from_broadcast(doc, prev)
      {board, change} = Board.apply_change(board, card)

      {:noreply,
       socket
       |> assign(:board, board)
       |> assign(:last_change, change)
       |> update(:seen, &MapSet.put(&1, key))}
    end
  end

  # Slow reconcile: a full snapshot re-derives the ready overlay + cascade
  # unblocks + the windowed done_today that a single optimistic event cannot,
  # and resets the done_today baseline to the authoritative value. Clear the
  # last flash so a stale marker doesn't linger, and reschedule.
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:noreply,
     socket
     |> assign(:board, Board.snapshot(dataset: socket.assigns.dataset))
     |> assign(:last_change, nil)}
  end

  # A non-task document event, or any other stray message — ignore it. NEVER
  # crash the socket over an event we don't render.
  def handle_info(_other, socket), do: {:noreply, socket}

  # ── wave 3: drag restage (charter D4/D11/D12) ──────────────────────────────
  #
  # The browser hook (`BarkparkBoardDrag`) pushes `restage` with the dragged
  # card's `doc_id` and the target column's `data-col`. We NEVER take the card's
  # possibly-stale board epoch on faith: we resolve the Default-workspace scope
  # (D12 — the same scope `tasks_controller` writes through) and FRESH-read the
  # live task row for its uuid pk, observed epoch, and true claim holder, then
  # let the pure `Board.restage_plan/4` decide which fenced primitive (if any)
  # the drop maps to. The write rides THIS per-socket event — no new process,
  # no raw Content write (charter D1/D5): a claim goes through
  # `Tasks.claim_by_id/3`, a close through `Tasks.close/3`, exactly as `bp` does.
  @impl true
  def handle_event("restage", %{"doc_id" => doc_id, "to_col" => to_col_raw}, socket) do
    with to_col when not is_nil(to_col) <- parse_col(to_col_raw),
         %{id: ws_id} <- Tenancy.get_default_workspace(),
         {:ok, %Document{} = doc} <- fetch_live_task(doc_id, ws_id),
         prev when not is_nil(prev) <- socket.assigns.board.cards_by_id[doc_id] do
      content = doc.content || %{}
      epoch = get_in(content, ["claim", "epoch"]) || 0
      holder = get_in(content, ["claim", "worker"])
      worker = worker_of(socket)
      plan = Board.restage_plan(prev.col, to_col, holder, worker)

      run_restage(socket, plan, %{
        doc_id: doc_id,
        task_id: doc.id,
        prev: prev,
        to_col: to_col,
        from_col: prev.col,
        holder: holder,
        worker: worker,
        epoch: epoch,
        scope: [workspace_id: ws_id]
      })
    else
      # No default workspace, an unknown column, a row that vanished, or a card
      # not on this board — refuse silently-but-visibly (never a raw write, never
      # a crash). The board is unchanged; a dismissible notice tells the user.
      _ -> {:noreply, assign(socket, :notice, "That drop can't be applied right now.")}
    end
  end

  # Dismiss the transient refusal banner.
  def handle_event("dismiss-notice", _params, socket) do
    {:noreply, assign(socket, :notice, nil)}
  end

  # A legal claim: OPTIMISTICALLY move the card to in_progress (D9 — the board
  # feels instant), THEN run the fence. On accept keep it (the real
  # `task.claimed` broadcast also arrives; the seen-set + idempotent
  # `apply_change/3` de-dupe). On refuse (a foreign in-flight card fences here
  # with `:not_ready`) roll back to the authoritative snapshot + notice.
  defp run_restage(socket, {:claim}, ctx) do
    socket = optimistic_move(socket, ctx.prev, "in_progress", ctx.worker)

    case Tasks.claim_by_id(ctx.doc_id, ctx.worker, ctx.scope) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, rollback(socket, "Couldn't claim that task — it may be held or blocked.")}
    end
  end

  # A legal close by the holder (`restage_plan/4` already guaranteed
  # `holder == worker`, so `close/3` — which fences on epoch, not identity — is
  # never called for a foreign hold). Optimistic move, then the fenced close.
  defp run_restage(socket, {:close, status}, ctx) do
    socket = optimistic_move(socket, ctx.prev, status, ctx.worker)

    case Tasks.close(ctx.task_id, ctx.worker, observed_epoch: ctx.epoch, lifecycle_status: status) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, rollback(socket, "Couldn't close that task — its claim moved under you.")}
    end
  end

  # No legal transition: never touch the model, never call a primitive — just
  # surface WHY (the card stays where the server last rendered it; the hook does
  # not reorder the DOM optimistically, so nothing needs snapping back).
  defp run_restage(socket, :refuse, ctx) do
    {:noreply,
     assign(socket, :notice, refuse_notice(ctx.from_col, ctx.to_col, ctx.holder, ctx.worker))}
  end

  # Optimistically re-bucket the dragged card to its target lifecycle so the
  # board moves the instant you drop (D9). We synthesize a normalized card off
  # the previous projection with the new lifecycle + worker and fold it through
  # the SAME pure `apply_change/3` the realtime broadcast uses, so the optimistic
  # move and the eventual real event converge on one card, one column.
  defp optimistic_move(socket, prev, lifecycle, worker) do
    card = %{prev | lifecycle_status: lifecycle, worker: worker}
    {board, change} = Board.apply_change(socket.assigns.board, card)

    socket
    |> assign(:board, board)
    |> assign(:last_change, change)
    |> assign(:notice, nil)
  end

  # A refused/failed write snaps the board back to the authoritative DB state
  # (D9) so a rejected optimistic move never lingers, and raises the notice.
  defp rollback(socket, message) do
    socket
    |> assign(:board, Board.snapshot(dataset: socket.assigns.dataset))
    |> assign(:last_change, nil)
    |> assign(:notice, message)
  end

  # The acting worker for a Studio-driven write: `studio:<current-user>` when an
  # account session resolved a User (D11), else `studio:admin` for the thin
  # api-token conns (Studio's default posture) and tests. The colon-prefixed
  # namespace keeps a board-driven claim legible next to `cmux-*` / bp workers.
  defp worker_of(socket) do
    case socket.assigns[:current_user] do
      %{email: email} when is_binary(email) and email != "" -> "studio:" <> email
      _ -> "studio:admin"
    end
  end

  # Fresh-read the live task row scoped to the Default workspace (D12 — the same
  # scope `tasks_controller` writes through), with the exact/`drafts.` fallback
  # `find_task_by_doc_id`/`claim_by_id` use so a mutate-created `drafts.<id>` row
  # resolves from its published logical id.
  defp fetch_live_task(doc_id, ws_id) do
    case fetch_task_exact(doc_id, ws_id) do
      {:ok, _} = hit ->
        hit

      :error ->
        if String.starts_with?(doc_id, "drafts."),
          do: :error,
          else: fetch_task_exact("drafts." <> doc_id, ws_id)
    end
  end

  defp fetch_task_exact(doc_id, ws_id) do
    query =
      from(d in Document, where: d.doc_id == ^doc_id and d.type == "task")
      |> Scope.scope_to_workspace(ws_id, nil)

    case Repo.one(query) do
      nil -> :error
      %Document{} = doc -> {:ok, doc}
    end
  end

  # A plain-English reason for a refused drop — the always-a-next-step signal so
  # a refusal reads as guidance, not a dead end (§0). Presentation-only; the
  # legality itself is `Board.restage_plan/4`'s pure verdict.
  defp refuse_notice(from_col, to_col, holder, worker) do
    cond do
      to_col == :ready ->
        "Ready is derived from a task's dependencies — you can't drop a card there."

      to_col == :open ->
        "Reopening a task from the board isn't supported yet."

      from_col == :done ->
        "Done tasks stay put — drag lands one-way down the ladder."

      from_col == :in_progress and holder not in [nil, worker] ->
        "@#{holder} holds this task — only the holder can move it to Done or Blocked."

      to_col in [:done, :blocked] and from_col != :in_progress ->
        "Claim the task first (drop it on In Progress), then you can close it."

      true ->
        "That move isn't a valid step."
    end
  end

  # A safe column parse — a whitelist off `Board.columns/0`, NEVER
  # `String.to_atom/1` on wire input (that would leak the atom table to a
  # crafted `to_col`). Returns the atom or nil.
  defp parse_col(raw) when is_binary(raw) do
    Enum.find(Board.columns(), fn col -> Atom.to_string(col) == raw end)
  end

  defp parse_col(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      /* Barkpark Projects board — §1/§2 task design-language vocabulary.
         Self-contained + CSP-safe (pulse's inline discipline). Curly braces
         inside <style> are verbatim in HEEx 1.x — no interpolation here. */
      .bp-board-wrap { max-width: 82rem; }
      .bp-momentum {
        display: flex; align-items: center; gap: 1.4rem; flex-wrap: wrap;
        font-variant-numeric: tabular-nums; margin: 0.4rem 0 0.2rem;
        font-size: 1.05rem;
      }
      .bp-momentum .m-pct { font-weight: 700; margin-left: auto; }
      .bp-bar {
        height: 8px; border-radius: 999px; margin: 0.6rem 0 1.4rem;
        background: var(--muted-border-color, rgba(127,127,127,0.22));
        overflow: hidden;
      }
      .bp-bar-fill {
        height: 100%; border-radius: 999px;
        background: linear-gradient(90deg, #2563eb, #0d9488);
        transition: width 900ms cubic-bezier(0.22, 1, 0.36, 1);
      }

      .bp-board {
        display: grid;
        grid-template-columns: repeat(5, minmax(0, 1fr));
        gap: 0.9rem; align-items: start;
      }
      @media (max-width: 60rem) { .bp-board { grid-template-columns: 1fr; } }
      .bp-col { min-width: 0; }
      .bp-col-h {
        display: flex; align-items: baseline; gap: 0.5rem;
        font-size: 0.78rem; letter-spacing: 0.06em; text-transform: uppercase;
        opacity: 0.6; margin: 0 0 0.6rem; font-weight: 600;
      }
      .bp-col-n { opacity: 0.7; font-variant-numeric: tabular-nums; }
      .bp-col-empty { opacity: 0.35; font-size: 0.85rem; padding: 0.3rem 0; }

      .bp-card {
        border: 1px solid var(--muted-border-color, rgba(127,127,127,0.28));
        border-radius: 10px; padding: 0.6rem 0.7rem; margin: 0 0 0.6rem;
        background: var(--card-background-color, rgba(127,127,127,0.04));
      }
      .bp-card--done { opacity: 0.62; }

      /* Drag restage (wave 3) — pure-CSS affordances (CSP-safe, no JS styling).
         A card is draggable="true"; while dragging it dims + shows the grab
         cursor, and the column under the pointer lights (ok) or hatches (no)
         via a .bp-drop-ok/.bp-drop-no class the hook toggles on dragover. Ready
         is a non-drop column (D3) → it always reads .bp-drop-no. */
      .bp-card[draggable="true"] { cursor: grab; }
      .bp-card.bp-card-dragging { opacity: 0.45; cursor: grabbing; }
      .bp-col.bp-drop-ok {
        border-radius: 10px;
        box-shadow: inset 0 0 0 2px rgba(37,99,235,0.55);
        background: rgba(37,99,235,0.06);
      }
      .bp-col.bp-drop-no {
        border-radius: 10px;
        box-shadow: inset 0 0 0 2px rgba(127,127,127,0.35);
        background: rgba(127,127,127,0.06);
      }

      /* Refusal / rollback banner — a dismissible status line so a refused drop
         reads as guidance, not a dead end (§0 "always a next step"). CSS fade-in
         only; frozen under prefers-reduced-motion below. */
      .bp-notice {
        display: flex; align-items: center; gap: 0.6rem;
        margin: 0 0 1rem; padding: 0.55rem 0.8rem; border-radius: 8px;
        font-size: 0.9rem; border: 1px solid #d97706;
        background: rgba(217,119,6,0.12);
        animation: bp-notice-in 260ms ease-out 1;
      }
      .bp-notice-text { flex: 1 1 auto; }
      .bp-notice-x {
        flex: 0 0 auto; cursor: pointer; border: 0; background: transparent;
        font-size: 1.15rem; line-height: 1; padding: 0 0.2rem; color: inherit;
        opacity: 0.7;
      }
      .bp-notice-x:hover { opacity: 1; }
      @keyframes bp-notice-in {
        0%   { opacity: 0; transform: translateY(-4px); }
        100% { opacity: 1; transform: translateY(0); }
      }

      /* Realtime flash (wave 2) — the just-changed card pulses its border + a
         soft wash so the eye lands on the movement (§0 "you watch momentum").
         Applied via a `.bp-flash` class the render adds ONLY to the one card in
         `@last_change`; a class change replays the animation, and a moved card
         is re-created in its new column so it animates on mount too. CSS-only,
         CSP-safe. `phx-mounted` belt-and-braces re-runs it for a re-inserted
         node in browsers. */
      .bp-flash { animation: bp-flash 900ms ease-out 1; }
      @keyframes bp-flash {
        0%   { box-shadow: 0 0 0 0 rgba(37,99,235,0.55); background: rgba(37,99,235,0.14); }
        60%  { box-shadow: 0 0 0 4px rgba(37,99,235,0.0); }
        100% { box-shadow: 0 0 0 0 rgba(37,99,235,0.0); }
      }

      /* The done-today tally gives a brief scale bump on a fresh close so the
         climbing number is felt, not just read. */
      .m-bump { animation: bp-bump 700ms cubic-bezier(0.34, 1.56, 0.64, 1) 1; display: inline-block; }
      @keyframes bp-bump {
        0%   { transform: scale(1); }
        40%  { transform: scale(1.28); color: #0d9488; }
        100% { transform: scale(1); }
      }
      .bp-card-top { display: flex; align-items: flex-start; gap: 0.5rem; }
      .bp-title { font-weight: 600; font-size: 0.92rem; line-height: 1.3; }
      .bp-meta {
        display: flex; flex-wrap: wrap; gap: 0.4rem 0.55rem;
        margin-top: 0.5rem; font-size: 0.74rem; align-items: center;
      }
      .bp-pip {
        font-variant-numeric: tabular-nums; font-weight: 700;
        padding: 0.02rem 0.32rem; border-radius: 5px;
        background: rgba(127,127,127,0.14);
      }
      .bp-goal {
        opacity: 0.85; padding: 0.02rem 0.32rem; border-radius: 5px;
        background: rgba(37,99,235,0.12);
      }
      .bp-goal::before { content: "↳ "; opacity: 0.7; }
      .bp-label {
        opacity: 0.7; padding: 0.02rem 0.3rem; border-radius: 5px;
        background: rgba(127,127,127,0.10);
      }
      .bp-worker { opacity: 0.8; }
      .bp-worker::before { content: "@"; opacity: 0.6; }
      .bp-crit {
        font-variant-numeric: tabular-nums; opacity: 0.85;
        padding: 0.02rem 0.3rem; border-radius: 5px;
        background: rgba(13,148,136,0.12);
      }

      /* ── §1 white-ladder glyph vocabulary ────────────────────────────── */
      .gi {
        display: inline-block; width: 1.1em; text-align: center;
        font-family: var(--font-mono, monospace); line-height: 1.3;
      }
      .gi--open { color: currentColor; opacity: 0.5; }      /* backlog: dim ○ */
      .gi--ready { color: currentColor; opacity: 1; }       /* unchecked: bright ○ */
      .gi--blocked { color: #d97706; font-weight: 700; }    /* amber ! */
      .gi--done { color: #0d9488; }                          /* teal ✓ */
      .gi--cancelled { color: #a1a1aa; }

      /* in_progress: pure-CSS Braille spinner, TUI-identical 10 frames,
         ~80ms/frame (800ms cycle). The glyph is supplied entirely by ::before
         so the frame-cycle needs no JS and survives a static render. */
      .gi--in_progress { color: #2563eb; }
      .gi--in_progress::before { content: "⠋"; animation: bp-braille 800ms steps(1) infinite; }
      @keyframes bp-braille {
        0%   { content: "⠋"; }
        10%  { content: "⠙"; }
        20%  { content: "⠹"; }
        30%  { content: "⠸"; }
        40%  { content: "⠼"; }
        50%  { content: "⠴"; }
        60%  { content: "⠦"; }
        70%  { content: "⠧"; }
        80%  { content: "⠇"; }
        90%  { content: "⠏"; }
      }

      /* GitHub badge — issue # + sync dot + click-through. */
      .bp-gh {
        display: inline-flex; align-items: center; gap: 0.28rem;
        text-decoration: none; font-variant-numeric: tabular-nums;
        padding: 0.02rem 0.34rem; border-radius: 5px; opacity: 0.9;
        border: 1px solid var(--muted-border-color, rgba(127,127,127,0.3));
      }
      .bp-gh:hover { opacity: 1; }
      .bp-gh-dot { width: 7px; height: 7px; border-radius: 999px; display: inline-block; }
      .bp-gh-dot.is-synced { background: #2dd4bf; }
      .bp-gh-dot.is-detached { background: #d97706; }
      .bp-gh-state { opacity: 0.6; }
      .bp-cancelled {
        margin: 1.2rem 0 0; opacity: 0.5; font-size: 0.85rem;
        color: #a1a1aa; font-variant-numeric: tabular-nums;
      }

      /* Dark-scheme §1 hexes (lighter, higher-contrast on dark surfaces). */
      @media (prefers-color-scheme: dark) {
        .gi--blocked { color: #fbbf24; }
        .gi--done { color: #2dd4bf; }
        .gi--cancelled, .bp-cancelled { color: #71717a; }
        .gi--in_progress { color: #60a5fa; }
      }

      /* Motion is a signal, not decoration — honor the reader's preference. */
      @media (prefers-reduced-motion: reduce) {
        .gi--in_progress::before { animation: none; content: "⠿"; }
        .bp-bar-fill { transition: none; }
        .bp-flash { animation: none; }
        .m-bump { animation: none; }
        .bp-notice { animation: none; }
      }
    </style>

    <main class="container bp-board-wrap">
      <h1>▦ Projects</h1>
      <p>
        <small>
          A live board over the real task documents — it MOVES: claim or close a
          task anywhere and its card flashes, re-buckets, and the tally climbs.
          Columns are the status ladder; drag a card to In&nbsp;Progress to claim
          it, or drop your own onto Done or Blocked to close it.
        </small>
      </p>

      <header class="bp-momentum" data-role="momentum">
        <span data-role="m-inflight">◐ <%= @board.momentum.in_flight %> in flight</span>
        <span data-role="m-ready">○ <%= @board.momentum.ready %> ready</span>
        <span class={done_bump_class(@last_change)} data-role="m-done-today">✓ <%= @board.momentum.done_today %> done today</span>
        <span class="m-pct" data-role="m-pct"><%= @board.momentum.pct %>%</span>
      </header>
      <div class="bp-bar" data-role="momentum-bar">
        <div class="bp-bar-fill" style={"width: #{@board.momentum.pct}%;"}></div>
      </div>

      <div :if={@notice} class="bp-notice" data-role="notice" role="status">
        <span class="bp-notice-text"><%= @notice %></span>
        <button
          type="button"
          class="bp-notice-x"
          data-role="notice-dismiss"
          phx-click="dismiss-notice"
          aria-label="Dismiss"
        >×</button>
      </div>

      <div :if={empty_board?(@board)} data-role="board-empty">
        <p><em>No tasks yet — file one with <code>bp task create</code> and it appears here.</em></p>
      </div>

      <div
        id="bp-projects-board"
        class="bp-board"
        data-role="board"
        phx-hook="BarkparkBoardDrag"
      >
        <section :for={col <- Board.columns()} class="bp-col" data-role="column" data-col={col}>
          <h2 class="bp-col-h">
            <%= col_label(col) %>
            <span class="bp-col-n" data-role="col-count"><%= col_count(@board, col) %></span>
          </h2>

          <p :if={@board.columns[col] == []} class="bp-col-empty" data-role="col-empty">—</p>

          <article
            :for={card <- @board.columns[col]}
            class={["bp-card", "bp-card--#{col}", just_moved?(@last_change, card) && "bp-flash"]}
            data-role="task-card"
            data-col={col}
            data-doc-id={card.doc_id}
            data-just-moved={just_moved?(@last_change, card) && "true"}
            draggable="true"
          >
            <div class="bp-card-top">
              <span
                class={"gi gi--#{card.color_role}"}
                data-role="glyph"
                data-status={card.lifecycle_status}
                aria-hidden="true"
              >
                <%= glyph_text(card) %>
              </span>
              <span class="bp-title" data-role="card-title"><%= card.title %></span>
            </div>

            <div class="bp-meta">
              <span :if={card.priority} class="bp-pip" data-role="priority" data-priority={card.priority}>
                P<%= card.priority %>
              </span>
              <span :if={card.parent_id} class="bp-goal" data-role="goal"><%= card.parent_id %></span>
              <span :for={label <- card.labels} class="bp-label" data-role="label"><%= label %></span>
              <span :if={card.worker} class="bp-worker" data-role="worker"><%= card.worker %></span>
              <span :if={card.criteria} class="bp-crit" data-role="criteria">
                <%= card.criteria.met %>/<%= card.criteria.total %>
              </span>

              <a
                :if={github_badge?(card.github)}
                class="bp-gh"
                data-role="github-badge"
                data-issue={card.github["issue"]}
                href={gh_href(card.github)}
                target="_blank"
                rel="noopener"
              >
                <span
                  class={"bp-gh-dot " <> if(github_synced?(card), do: "is-synced", else: "is-detached")}
                  data-role="github-dot"
                >
                </span>
                #<%= card.github["issue"] %>
                <span class="bp-gh-state" data-role="github-state"><%= card.github["state"] %></span>
              </a>
            </div>
          </article>
        </section>
      </div>

      <p :if={@board.cancelled_count > 0} class="bp-cancelled" data-role="cancelled-tally">
        ✕ <%= @board.cancelled_count %> cancelled
      </p>
    </main>
    """
  end

  # ── Render helpers ──────────────────────────────────────────────────────────

  # The one card the last realtime event touched — the render flashes it (a
  # `bp-flash` class + a `data-just-moved` hook). nil `@last_change` (fresh mount
  # or post-refresh) flashes nothing.
  defp just_moved?(%{doc_id: id, kind: kind}, %{doc_id: id}) when kind != :ignored, do: true
  defp just_moved?(_change, _card), do: false

  # Bump the done-today tally only when the last event was a genuine close, so
  # the climbing number is felt at the moment it climbs.
  defp done_bump_class(%{kind: :closed}), do: "m-bump"
  defp done_bump_class(_), do: ""

  # The column count. Every column renders its live card count EXCEPT :done, whose
  # rendered list is WINDOWED at @done_window (D10) — so it reports the FULL
  # `done_total` instead, or the pile would freeze at 12 and closing your 13th
  # task would not visibly grow "Done" (violating §0 "you always feel progress").
  defp col_count(board, :done), do: board.done_total
  defp col_count(board, col), do: length(board.columns[col])

  defp col_label(:open), do: "Open"
  defp col_label(:ready), do: "Ready"
  defp col_label(:in_progress), do: "In Progress"
  defp col_label(:blocked), do: "Blocked"
  defp col_label(:done), do: "Done"

  # in_progress renders its (animated) glyph entirely from CSS `::before`, so the
  # span body is empty — every other state prints the literal §1 Unicode char.
  defp glyph_text(%{color_role: :in_progress}), do: ""
  defp glyph_text(%{glyph: glyph}), do: glyph

  defp gh_href(%{"repo" => repo, "issue" => issue})
       when is_binary(repo) and (is_integer(issue) or is_binary(issue)),
       do: "https://github.com/#{repo}/issues/#{issue}"

  defp gh_href(_), do: "#"

  # A badge is shown only when the mirror carries an actual issue number — the
  # moduledoc/D7 promise is "the mirror-issue #number", so a partial `github`
  # stamp with no `issue` (e.g. a bare `%{"state" => "detached"}`) renders NO
  # badge rather than a fabricated `#`-with-no-number and a dead `#` link.
  defp github_badge?(%{"issue" => issue}) when not is_nil(issue), do: true
  defp github_badge?(_), do: false

  # The sync dot. `github_synced` is the organizer's derived `synced_rev == rev`
  # flag; read it via Access (never a dot-access KeyError) so a card projection
  # that omits the field degrades to the conservative "detached" dot instead of
  # crashing the whole board render.
  defp github_synced?(card), do: card[:github_synced] == true

  defp empty_board?(board) do
    board.cancelled_count == 0 and
      Enum.all?(Board.columns(), fn col -> board.columns[col] == [] end)
  end
end
