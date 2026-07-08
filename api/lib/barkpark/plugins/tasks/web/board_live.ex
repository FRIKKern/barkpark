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

  @facet_keys [:goal, :priority, :label, :worker]

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
     |> assign(:seen, MapSet.new())
     |> assign(:group_by, :none)
     |> assign(:filters, empty_filters())
     |> assign_view()}
  end

  # The board's grouping + filtering ride the URL (D14 — the ONLY mutation path,
  # so every view is shareable/bookmarkable). handle_params parses `?group=` +
  # the comma-joined facet params, WHITELISTING the group against
  # `Board.group_keys/0` (never `String.to_atom/1` on wire input — mirror
  # `parse_col/1`), then re-derives the pure view. It runs on the initial mount
  # and on every chip/selector push_patch.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:group_by, parse_group(params["group"]))
     |> assign(:filters, parse_filters(params))
     |> assign_view()}
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
       |> update(:seen, &MapSet.put(&1, key))
       |> assign_view()}
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
     |> assign(:last_change, nil)
     |> assign_view()}
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

  # ── wave 4: group-by + filter chips (charter D14 — URL is the mutation path) ─
  #
  # A chip/selector click never mutates assigns directly: it computes the NEXT
  # query and `push_patch`es to it, so `handle_params/3` is the single source of
  # truth (the view is always shareable/bookmarkable). Toggling a filter chip
  # adds/removes its value; the group selector swaps the grouping; clear-all
  # push_patches to the bare path.
  def handle_event("toggle-filter", %{"facet" => facet, "value" => value}, socket) do
    case facet_key(facet) do
      nil ->
        {:noreply, socket}

      key ->
        filters = toggle_filter(socket.assigns.filters, key, value)
        {:noreply, patch_to(socket, socket.assigns.group_by, filters)}
    end
  end

  def handle_event("set-group", %{"group" => group}, socket) do
    {:noreply, patch_to(socket, parse_group(group), socket.assigns.filters)}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/projects")}
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
    |> assign_view()
  end

  # A refused/failed write snaps the board back to the authoritative DB state
  # (D9) so a rejected optimistic move never lingers, and raises the notice.
  defp rollback(socket, message) do
    socket
    |> assign(:board, Board.snapshot(dataset: socket.assigns.dataset))
    |> assign(:last_change, nil)
    |> assign(:notice, message)
    |> assign_view()
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

  # ── wave 4: group/filter derivation + URL encoding (D14/D15) ────────────────

  # Re-derive the pure `Board.view/2` from the current @board + @group_by +
  # @filters. This is the D15 discipline: it is called at the END of mount, in
  # handle_params, AND in EVERY handler that reassigns @board (the realtime
  # re-bucket, the :refresh reconcile, and every optimistic-move/rollback path)
  # so the full model and the filtered view never drift.
  defp assign_view(socket) do
    view =
      Board.view(socket.assigns.board,
        group_by: socket.assigns.group_by,
        filters: socket.assigns.filters
      )

    assign(socket, :view, view)
  end

  defp empty_filters, do: Map.new(@facet_keys, fn key -> {key, []} end)

  # Whitelist the group param against Board.group_keys/0 (mirror parse_col/1 —
  # NEVER String.to_atom/1 on wire input), :none fallback.
  defp parse_group(raw) when is_binary(raw),
    do: Enum.find(Board.group_keys(), :none, fn g -> Atom.to_string(g) == raw end)

  defp parse_group(_), do: :none

  # Each facet param is comma-joined; split, trim, drop blanks. Always returns a
  # map with all four keys → a (possibly empty) string list.
  defp parse_filters(params) do
    Map.new(@facet_keys, fn key -> {key, split_csv(params[Atom.to_string(key)])} end)
  end

  defp split_csv(raw) when is_binary(raw) do
    raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp split_csv(_), do: []

  # Whitelist a facet name to its atom key (never String.to_atom/1 on wire input).
  defp facet_key(raw), do: Enum.find(@facet_keys, fn k -> Atom.to_string(k) == raw end)

  defp toggle_filter(filters, key, value) do
    current = Map.get(filters, key, [])
    updated = if value in current, do: List.delete(current, value), else: current ++ [value]
    Map.put(filters, key, updated)
  end

  defp facet_active?(filters, key, value), do: value in Map.get(filters, key, [])

  # push_patch to the URL encoding this (group, filters) pair — the ONLY mutation
  # path (D14). The bare path when nothing is selected keeps a clean, shareable URL.
  defp patch_to(socket, group_by, filters) do
    case board_query(group_by, filters) do
      [] -> push_patch(socket, to: ~p"/admin/projects")
      query -> push_patch(socket, to: ~p"/admin/projects?#{query}")
    end
  end

  defp board_query(group_by, filters) do
    group_params = if group_by == :none, do: [], else: [{"group", Atom.to_string(group_by)}]

    facet_params =
      for key <- @facet_keys, vals = Map.get(filters, key, []), vals != [] do
        {Atom.to_string(key), Enum.join(vals, ",")}
      end

    group_params ++ facet_params
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      /* Barkpark Projects board — §1/§2 task design-language vocabulary painted
         with the Studio token manifest (design/tokens.json → root layout vars:
         --bg/--surface/--muted-surface/--text/--muted-text/--border/--primary/
         --ok/--warn/--danger/--info + softs, --font, radii). Self-contained +
         CSP-safe (pulse's inline discipline). Curly braces inside <style> are
         verbatim in HEEx 1.x — no interpolation here. NOTE: theme flips ride
         html[data-theme="dark"] (the Studio toggle), never prefers-color-scheme
         alone. */
      /* The page is a flex CHILD of `.studio-shell` (height:100vh; overflow:
         hidden; flex column, with the topbar above and the build-version
         footer below). So it must FILL the remaining height and own its
         scroll — otherwise its content is clipped by the shell and nothing
         scrolls (the columns can't be reached). `flex: 1 1 auto` + `min-height:
         0` lets the board area below shrink and scroll. Full width (no
         max-width/auto-margin) so the kanban can scroll horizontally. */
      .bp-page {
        flex: 1 1 auto; min-height: 0;
        display: flex; flex-direction: column;
        padding: 20px clamp(16px, 2.5vw, 34px) 10px;
        font-family: var(--font, 'Inter', -apple-system, sans-serif);
        font-size: 13px; color: var(--text);
        -webkit-font-smoothing: antialiased;
        overflow: hidden;
      }

      /* ── page header: identity left, momentum right ───────────────────── */
      .bp-head {
        flex: 0 0 auto;
        display: flex; align-items: flex-end; justify-content: space-between;
        flex-wrap: wrap; gap: 18px 40px; margin: 2px 0 16px;
      }
      .bp-h1 {
        margin: 0; font-size: 20px; font-weight: 600;
        letter-spacing: -0.02em; line-height: 1.2; color: var(--text);
      }
      .bp-sub { margin: 5px 0 0; font-size: 13px; color: var(--muted-text); }
      .bp-head-r {
        display: flex; flex-direction: column; align-items: flex-end;
        gap: 8px; min-width: 260px;
      }
      .bp-momentum {
        display: flex; align-items: center; gap: 18px; flex-wrap: wrap;
        font-variant-numeric: tabular-nums; font-size: 13px;
      }
      .bp-stat {
        display: inline-flex; align-items: center; gap: 7px;
        color: var(--text); font-weight: 500; white-space: nowrap;
      }
      .bp-momentum .m-pct {
        font-weight: 600; font-size: 13px; color: var(--muted-text);
        padding-left: 14px; border-left: 1px solid var(--border);
      }
      .bp-bar {
        width: 100%; max-width: 320px; height: 4px; border-radius: 999px;
        background: var(--muted-surface); overflow: hidden;
      }
      .bp-bar-fill {
        height: 100%; border-radius: 999px;
        background: linear-gradient(90deg, var(--primary), var(--ok));
        transition: width 900ms cubic-bezier(0.22, 1, 0.36, 1);
      }

      /* ── toolbar: segmented group-by + filter disclosure + tally ────────── */
      .bp-controls {
        flex: 0 0 auto;
        display: flex; align-items: center; flex-wrap: wrap;
        gap: 10px 16px; margin: 0 0 14px;
      }
      .bp-group { display: inline-flex; align-items: center; gap: 10px; }
      .bp-controls-label {
        font-size: 11px; letter-spacing: 0.07em; text-transform: uppercase;
        color: var(--muted-text); font-weight: 600;
      }
      .bp-seg {
        display: inline-flex; align-items: center; gap: 2px;
        background: var(--muted-surface); border: 1px solid var(--border);
        border-radius: 8px; padding: 2px;
      }
      .bp-seg-opt {
        border: 0; background: transparent; color: var(--muted-text);
        font: inherit; font-size: 12px; font-weight: 500; line-height: 1.2;
        padding: 4px 11px; border-radius: 6px; cursor: pointer;
        transition: background 120ms ease, color 120ms ease, box-shadow 120ms ease;
      }
      .bp-seg-opt:hover { color: var(--text); }
      .bp-seg-opt.is-active {
        background: var(--surface); color: var(--text);
        box-shadow: 0 1px 2px rgb(0 0 0 / 0.08);
      }

      /* Filters fold behind a disclosure so the board — not a wall of every
         label/worker in the dataset — is the hero. Native <details>: CSP-safe,
         no JS, keyboard-native. Opens itself when a shared URL arrives
         pre-filtered so its active chips are visible; while open it takes the
         full toolbar row. */
      .bp-filters { display: inline-block; }
      .bp-filters[open] { flex-basis: 100%; }
      .bp-filters > summary {
        display: inline-flex; align-items: center; gap: 6px; width: max-content;
        cursor: pointer; user-select: none; list-style: none;
        font-size: 12px; font-weight: 500; color: var(--muted-text);
        padding: 4px 11px; border-radius: 6px; border: 1px solid transparent;
        transition: background 120ms ease, color 120ms ease;
      }
      .bp-filters > summary:hover { background: var(--muted-surface); color: var(--text); }
      .bp-filters > summary::-webkit-details-marker { display: none; }
      .bp-filters > summary::before {
        content: "\25B8"; display: inline-block; font-size: 10px;
        color: var(--muted-text); transition: transform 140ms ease;
      }
      .bp-filters[open] > summary::before { transform: rotate(90deg); }
      .bp-filters-active { color: var(--primary); font-weight: 600; }
      .bp-filters-body {
        display: flex; flex-direction: column; gap: 8px;
        margin-top: 10px; padding: 12px 14px; max-height: 38vh; overflow-y: auto;
        border: 1px solid var(--border); border-radius: 10px;
        background: var(--surface);
      }
      .bp-filters-body .bp-chip-row { max-height: 88px; overflow-y: auto; }
      .bp-chip-row {
        display: flex; flex-wrap: wrap; align-items: center; gap: 6px;
      }
      .bp-chip-row .bp-controls-label { min-width: 56px; }
      .bp-chip {
        font: inherit; font-size: 12px; line-height: 1.2;
        padding: 3px 10px; border-radius: 999px; cursor: pointer;
        color: var(--muted-text); border: 1px solid var(--border);
        background: var(--surface);
        transition: background 120ms ease, border-color 120ms ease, color 120ms ease;
      }
      .bp-chip:hover { border-color: var(--ring); color: var(--text); }
      .bp-chip.is-active {
        border-color: var(--primary); color: var(--primary-fg);
        background: var(--primary);
      }
      .bp-chip:focus-visible, .bp-seg-opt:focus-visible,
      .bp-filters > summary:focus-visible {
        outline: 2px solid var(--ring); outline-offset: 1px;
      }
      .bp-clear { opacity: 0.85; margin-left: auto; }
      .bp-clear:hover { opacity: 1; }
      .bp-cancelled {
        margin-left: auto; color: var(--muted-text); font-size: 12px;
        font-variant-numeric: tabular-nums;
      }

      /* ── swimlanes (grouped view) ───────────────────────────────────────── */
      /* Grouped mode stacks several boards, so it scrolls VERTICALLY as a whole
         (the flat mode's fill-and-h-scroll model doesn't apply). The scroll
         wrapper takes the page's remaining height; each lane's board still
         scrolls horizontally within it. */
      .bp-lanes { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding-right: 2px; }
      .bp-lane { margin: 0 0 22px; }
      .bp-lane-h {
        font-size: 13px; font-weight: 600; letter-spacing: -0.01em;
        margin: 0 0 10px; padding: 0 2px 8px; color: var(--text);
        border-bottom: 1px solid var(--border);
      }
      .bp-filtered-empty {
        display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
        margin: 18px 0; color: var(--muted-text); font-size: 13px;
      }
      .bp-filtered-empty p { margin: 0; }
      .bp-board-empty {
        margin: 18px 0; padding: 56px 24px; text-align: center;
        border: 1px dashed var(--border); border-radius: 12px;
        color: var(--muted-text); font-size: 13px;
      }
      .bp-board-empty p { margin: 0; }

      /* ── the board: a single horizontal row of status-ladder panels ──────
         ALWAYS a horizontal-scroll kanban — never a reflowing grid. The five
         columns sit in one flex row that never wraps; when they can't all fit
         the board scrolls sideways (like Linear / GitHub Projects / Trello).
         In flat mode the board fills the page's remaining height so each
         column scrolls VERTICALLY on its own; horizontal scroll lives here. */
      .bp-board {
        flex: 1 1 auto; min-height: 0;
        display: flex; flex-wrap: nowrap; align-items: stretch;
        gap: 12px; overflow-x: auto; overflow-y: hidden;
        padding-bottom: 8px;
        scrollbar-width: thin; scrollbar-color: var(--border) transparent;
      }
      .bp-board::-webkit-scrollbar { height: 10px; }
      .bp-board::-webkit-scrollbar-thumb { background: var(--border); border-radius: 999px; }
      /* Grouped lanes are shorter (auto height, page scrolls) — cap each
         lane's column height so a tall lane doesn't run off the page. */
      .bp-lane .bp-board { flex: 0 0 auto; }
      .bp-lane .bp-col-scroll { max-height: 60vh; }
      .bp-col {
        flex: 0 0 336px; width: 336px; min-width: 0;
        display: flex; flex-direction: column; min-height: 0;
        background: var(--muted-surface);
        background: color-mix(in srgb, var(--muted-surface) 55%, transparent);
        border: 1px solid var(--border); border-radius: 12px; padding: 8px;
      }
      .bp-col-h {
        display: flex; align-items: center; gap: 7px;
        font-size: 11px; letter-spacing: 0.07em; text-transform: uppercase;
        color: var(--muted-text); font-weight: 600;
        margin: 2px 2px 8px; padding: 3px 5px;
      }
      .bp-col-h .gi { font-size: 12px; }
      .bp-col-n {
        margin-left: auto; font-variant-numeric: tabular-nums; letter-spacing: 0;
        font-size: 11px; color: var(--muted-text);
        background: var(--surface); border: 1px solid var(--border);
        border-radius: 999px; padding: 1px 8px;
      }
      .bp-col-scroll {
        display: flex; flex-direction: column; gap: 8px;
        flex: 1 1 auto; min-height: 0; overflow-y: auto;
        padding: 1px; scrollbar-width: thin; scrollbar-color: var(--border) transparent;
      }
      .bp-col-scroll::-webkit-scrollbar { width: 8px; }
      .bp-col-scroll::-webkit-scrollbar-thumb {
        background: var(--border); border-radius: 999px;
      }
      .bp-col-empty {
        margin: 0; padding: 20px 0; text-align: center;
        border: 1px dashed var(--border); border-radius: 8px;
        color: var(--muted-text); opacity: 0.6; font-size: 12px;
      }

      /* ── cards ──────────────────────────────────────────────────────────── */
      .bp-card {
        background: var(--surface); border: 1px solid var(--border);
        border-radius: 10px; padding: 10px 12px;
        transition: border-color 120ms ease, box-shadow 120ms ease;
      }
      .bp-card:hover {
        border-color: color-mix(in srgb, var(--border) 45%, var(--muted-text));
        box-shadow: 0 2px 8px rgb(0 0 0 / 0.06);
      }
      .bp-card--done { opacity: 0.55; }
      .bp-card--done .bp-title { font-weight: 400; }

      /* Drag restage (wave 3) — pure-CSS affordances (CSP-safe, no JS styling).
         A card is draggable="true"; while dragging it dims + shows the grab
         cursor, and the column under the pointer lights (ok) or hatches (no)
         via a .bp-drop-ok/.bp-drop-no class the hook toggles on dragover. Ready
         is a non-drop column (D3) → it always reads .bp-drop-no. */
      .bp-card[draggable="true"] { cursor: grab; }
      .bp-card.bp-card-dragging { opacity: 0.45; cursor: grabbing; }
      .bp-col.bp-drop-ok {
        box-shadow: inset 0 0 0 2px var(--ring);
        background: color-mix(in srgb, var(--ring) 7%, transparent);
      }
      .bp-col.bp-drop-no {
        box-shadow: inset 0 0 0 2px var(--border);
        background: var(--muted-surface);
      }

      /* Refusal / rollback banner — a dismissible status line so a refused drop
         reads as guidance, not a dead end (§0 "always a next step"). CSS fade-in
         only; frozen under prefers-reduced-motion below. */
      .bp-notice {
        display: flex; align-items: center; gap: 10px;
        margin: 0 0 14px; padding: 8px 12px; border-radius: 8px;
        font-size: 12.5px; color: var(--text);
        border: 1px solid var(--warn); background: var(--warn-soft);
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
      .m-bump { animation: bp-bump 700ms cubic-bezier(0.34, 1.56, 0.64, 1) 1; display: inline-flex; }
      @keyframes bp-bump {
        0%   { transform: scale(1); }
        40%  { transform: scale(1.22); color: var(--ok); }
        100% { transform: scale(1); }
      }
      .bp-card-top { display: flex; align-items: flex-start; gap: 8px; }
      .bp-card-top .gi { margin-top: 1px; }
      .bp-title {
        font-weight: 500; font-size: 13px; line-height: 1.4; color: var(--text);
      }
      .bp-meta {
        display: flex; flex-wrap: wrap; gap: 5px 6px;
        margin-top: 8px; font-size: 11px; align-items: center;
        color: var(--muted-text);
      }
      .bp-pip, .bp-goal, .bp-label, .bp-crit {
        padding: 1.5px 7px; border-radius: 5px; line-height: 1.5;
        font-variant-numeric: tabular-nums; white-space: nowrap;
      }
      .bp-pip { background: var(--muted-surface); color: var(--muted-text); font-weight: 600; }
      .bp-pip[data-priority="0"] { background: var(--danger-soft); color: var(--danger); }
      .bp-pip[data-priority="1"] { background: var(--warn-soft); color: var(--warn); }
      .bp-goal { background: var(--info-soft); color: var(--info); }
      .bp-goal::before { content: "↳ "; opacity: 0.7; }
      .bp-label { background: var(--muted-surface); color: var(--muted-text); }
      .bp-worker { color: var(--muted-text); }
      .bp-worker::before { content: "@"; opacity: 0.65; }
      .bp-crit { background: var(--ok-soft); color: var(--ok); font-weight: 600; }
      .bp-crit--zero { background: var(--muted-surface); color: var(--muted-text); }

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
        display: inline-flex; align-items: center; gap: 5px;
        text-decoration: none; font-variant-numeric: tabular-nums;
        padding: 1px 8px; border-radius: 999px; line-height: 1.5;
        color: var(--muted-text); border: 1px solid var(--border);
        transition: border-color 120ms ease, color 120ms ease;
      }
      .bp-gh:hover { color: var(--text); border-color: var(--ring); }
      .bp-gh-dot { width: 6px; height: 6px; border-radius: 999px; display: inline-block; }
      .bp-gh-dot.is-synced { background: #2dd4bf; }
      .bp-gh-dot.is-detached { background: #d97706; }
      .bp-gh-state { opacity: 0.65; }

      /* Dark-scheme §1 hexes (lighter, higher-contrast on dark surfaces) —
         keyed off the Studio theme attribute, with the media query as the
         pre-hydration fallback. */
      @media (prefers-color-scheme: dark) {
        .gi--blocked { color: #fbbf24; }
        .gi--done { color: #2dd4bf; }
        .gi--cancelled { color: #71717a; }
        .gi--in_progress { color: #60a5fa; }
        .bp-card:hover { box-shadow: 0 2px 10px rgb(0 0 0 / 0.35); }
        .bp-seg-opt.is-active { box-shadow: 0 1px 2px rgb(0 0 0 / 0.4); }
      }
      html[data-theme="light"] .gi--blocked { color: #d97706; }
      html[data-theme="light"] .gi--done { color: #0d9488; }
      html[data-theme="light"] .gi--cancelled { color: #a1a1aa; }
      html[data-theme="light"] .gi--in_progress { color: #2563eb; }
      html[data-theme="dark"] .gi--blocked { color: #fbbf24; }
      html[data-theme="dark"] .gi--done { color: #2dd4bf; }
      html[data-theme="dark"] .gi--cancelled { color: #71717a; }
      html[data-theme="dark"] .gi--in_progress { color: #60a5fa; }
      html[data-theme="dark"] .bp-card:hover { box-shadow: 0 2px 10px rgb(0 0 0 / 0.35); }

      /* Motion is a signal, not decoration — honor the reader's preference. */
      @media (prefers-reduced-motion: reduce) {
        .gi--in_progress::before { animation: none; content: "⠿"; }
        .bp-bar-fill { transition: none; }
        .bp-flash { animation: none; }
        .m-bump { animation: none; }
        .bp-notice { animation: none; }
        .bp-chip { transition: none; }
      }
    </style>

    <main class="bp-page">
      <div class="bp-head">
        <div class="bp-head-l">
          <h1 class="bp-h1">Projects</h1>
          <p class="bp-sub">
            Every task, live — drag a card to claim it, block it, or close it.
          </p>
        </div>
        <div class="bp-head-r">
          <header class="bp-momentum" data-role="momentum">
            <span class="bp-stat" data-role="m-inflight"><span
              class="gi gi--in_progress"
              aria-hidden="true"
            ></span><%= @view.momentum.in_flight %> in flight</span>
            <span class="bp-stat" data-role="m-ready"><span
              class="gi gi--ready"
              aria-hidden="true"
            >○</span><%= @view.momentum.ready %> ready</span>
            <span class={["bp-stat", done_bump_class(@last_change)]} data-role="m-done-today"><span
              class="gi gi--done"
              aria-hidden="true"
            >✓</span><%= @view.momentum.done_today %> done today</span>
            <span class="m-pct" data-role="m-pct"><%= @view.momentum.pct %>%</span>
          </header>
          <div class="bp-bar" data-role="momentum-bar">
            <div class="bp-bar-fill" style={"width: #{@view.momentum.pct}%;"}></div>
          </div>
        </div>
      </div>

      <%= render_controls(assigns) %>

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

      <div :if={empty_board?(@board)} class="bp-board-empty" data-role="board-empty">
        <p>No tasks yet — file one with <code>bp task create</code> and it appears here.</p>
      </div>

      <div
        :if={@view.empty? and not empty_board?(@board)}
        class="bp-filtered-empty"
        data-role="filtered-empty"
      >
        <p><em>No tasks match — clear the filters to see the whole board.</em></p>
        <button type="button" class="bp-chip bp-clear" phx-click="clear-filters" data-role="clear-all">
          Clear filters
        </button>
      </div>

      <%= unless @view.empty? and not empty_board?(@board) do %>
        <%= if @view.grouped? do %>
          <div class="bp-lanes">
            <section
              :for={lane <- @view.lanes}
              class="bp-lane"
              data-role="lane"
              data-lane={lane_dom_id(lane.key)}
            >
              <h2 class="bp-lane-h" data-role="lane-label"><%= lane.label %></h2>
              <.board_grid
                lane={lane}
                last_change={@last_change}
                id={"bp-board-lane-" <> lane_dom_id(lane.key)}
              />
            </section>
          </div>
        <% else %>
          <.board_grid lane={hd(@view.lanes)} last_change={@last_change} id="bp-projects-board" />
        <% end %>
      <% end %>

    </main>
    """
  end

  # ── the controls: group selector + filter chips (wave 4) ────────────────────
  #
  # A chip menu that offers ONLY the facets that exist (@view.facets), pure-CSS +
  # CSP-safe: each chip is a <button> whose phx-click computes the next URL and
  # push_patches (D14). Active chips carry aria-pressed + .is-active. No inline JS.
  defp render_controls(assigns) do
    ~H"""
    <section class="bp-controls" data-role="controls">
      <div class="bp-group" data-role="group-select">
        <span class="bp-controls-label">Group</span>
        <div class="bp-seg" role="group" aria-label="Group the board by">
          <button
            :for={g <- Board.group_keys()}
            type="button"
            class={["bp-seg-opt", @group_by == g && "is-active"]}
            aria-pressed={to_string(@group_by == g)}
            phx-click="set-group"
            phx-value-group={g}
            data-role="group-option"
            data-group={g}
          >
            <%= group_label(g) %>
          </button>
        </div>
      </div>

      <details
        :if={any_facets?(@view)}
        class="bp-filters"
        data-role="filters"
        open={@view.filtered?}
      >
        <summary class="bp-filters-summary" data-role="filters-toggle">
          Filter<span
            :if={@view.filtered?}
            class="bp-filters-active"
            data-role="filters-active"
          > · active</span>
        </summary>
        <div class="bp-filters-body">
          <.chip_row
            :if={@view.facets.goals != []}
            facet={:goal}
            title="Goal"
            prefix="↳"
            values={@view.facets.goals}
            filters={@filters}
          />
          <.chip_row
            :if={@view.facets.priorities != []}
            facet={:priority}
            title="Priority"
            prefix="P"
            values={@view.facets.priorities}
            filters={@filters}
          />
          <.chip_row
            :if={@view.facets.labels != []}
            facet={:label}
            title="Label"
            prefix="#"
            values={@view.facets.labels}
            filters={@filters}
          />
          <.chip_row
            :if={@view.facets.workers != []}
            facet={:worker}
            title="Worker"
            prefix="@"
            values={@view.facets.workers}
            filters={@filters}
          />

          <button
            :if={@view.filtered?}
            type="button"
            class="bp-chip bp-clear"
            phx-click="clear-filters"
            data-role="clear-all"
          >
            Clear filters
          </button>
        </div>
      </details>

      <span :if={@board.cancelled_count > 0} class="bp-cancelled" data-role="cancelled-tally">
        ✕ <%= @board.cancelled_count %> cancelled
      </span>
    </section>
    """
  end

  # Any facet value at all present in the (already-fetched) corpus? Gates the
  # whole filter disclosure — no chrome when there is nothing to filter.
  defp any_facets?(view) do
    f = view.facets
    f.goals != [] or f.priorities != [] or f.labels != [] or f.workers != []
  end

  # One facet's row of toggle chips. `facet` is the atom key (`:goal` …); HEEx
  # renders it to its string for the wire attrs.
  defp chip_row(assigns) do
    ~H"""
    <div class="bp-chip-row" data-role={"facet-#{@facet}"}>
      <span class="bp-controls-label"><%= @title %></span>
      <button
        :for={value <- @values}
        type="button"
        class={["bp-chip", facet_active?(@filters, @facet, value) && "is-active"]}
        aria-pressed={to_string(facet_active?(@filters, @facet, value))}
        phx-click="toggle-filter"
        phx-value-facet={@facet}
        phx-value-value={value}
        data-role="chip"
        data-facet={@facet}
      >
        <%= @prefix %><%= value %>
      </button>
    </div>
    """
  end

  # One swimlane's 5-column grid — the SAME flat structure the ungrouped board
  # renders (grouped mode stacks several of these, each with its own hook id).
  defp board_grid(assigns) do
    ~H"""
    <div id={@id} class="bp-board" data-role="board" phx-hook="BarkparkBoardDrag">
      <section :for={col <- Board.columns()} class="bp-col" data-role="column" data-col={col}>
        <h2 class="bp-col-h">
          <span class={"gi gi--#{col}"} aria-hidden="true"><%= col_glyph(col) %></span>
          <%= col_label(col) %>
          <span class="bp-col-n" data-role="col-count"><%= @lane.counts[col] %></span>
        </h2>

        <div class="bp-col-scroll">
          <p :if={@lane.columns[col] == []} class="bp-col-empty" data-role="col-empty">—</p>

          <article
          :for={card <- @lane.columns[col]}
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
            <span
              :if={card.criteria}
              class={["bp-crit", card.criteria.met == 0 && "bp-crit--zero"]}
              data-role="criteria"
            >
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
        </div>
      </section>
    </div>
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

  # A group-selector option's label.
  defp group_label(:none), do: "None"
  defp group_label(:goal), do: "Goal"
  defp group_label(:priority), do: "Priority"
  defp group_label(:label), do: "Label"

  # A DOM-safe id fragment for a lane's hook id / data-lane attr. The `:all`
  # passthrough lane and the none-lane get stable slugs; a facet value is
  # sanitized (non-alphanumerics → `-`) so a label like `proj:board` yields a
  # valid element id.
  defp lane_dom_id(:all), do: "all"
  defp lane_dom_id(nil), do: "none"
  defp lane_dom_id(key) when is_binary(key), do: String.replace(key, ~r/[^a-zA-Z0-9]+/, "-")
  defp lane_dom_id(key), do: lane_dom_id(to_string(key))

  defp col_label(:open), do: "Open"
  defp col_label(:ready), do: "Ready"
  defp col_label(:in_progress), do: "In Progress"
  defp col_label(:blocked), do: "Blocked"
  defp col_label(:done), do: "Done"

  # The column header's §1 ladder glyph. in_progress paints entirely from the
  # CSS `::before` spinner (same as the card glyph), so its span body is empty.
  defp col_glyph(:in_progress), do: ""
  defp col_glyph(col), do: Board.glyphs()[col]

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
