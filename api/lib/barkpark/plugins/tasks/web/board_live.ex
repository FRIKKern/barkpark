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

  When a `{:document_changed, %{type: "task"}}` arrives, `Board.card_from_broadcast/3`
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

  ## Signal pass (wave 10)

  Less clutter, more structure: every card stamps a relative age; acceptance
  criteria render as a real progress row (track + n/m) instead of a chip;
  labels cap at two (+N); the worker anchors the meta row's right edge; a
  blocked card states how many blockers are still live; and the Done column
  compacts to a one-line ledger (✓ title · age) with an honest "+N earlier"
  window note off `done_total` — history stays readable without competing with
  the active pipeline for the eye.

  ## Settled lanes (wave 11)

  A lane with done work and ZERO live pipeline earns a receipt, not five
  columns of nothing: in grouped mode it collapses to a one-line `<details>`
  summary (✓ label · all N done · last age) that expands to its done ledger;
  a fully-settled flat board swaps the column skeleton for a "pipeline clear"
  state (hero + ledger + window note). Empty columns stay ONLY while something
  is live — they are drag drop-targets then; a settled lane has none.

  ## Focus & lineage (wave 12)

  What's in focus gets the detail: the In Progress column is wider (400px vs
  336px), and each in-flight card carries a `now:` focus line naming the step
  being worked — its in-flight subtask (title + worker; the TUI
  activity-focus) or, when it has no children, the first unmet acceptance
  criterion. Any card with children shows a `done/total sub` lineage pill
  (organizer-derived from `parent_id` over the same corpus).

  ## Family cards (wave 16)

  The default (ungrouped, unfiltered) board folds every task whose parent is
  on the board INTO its root's card — fewer, larger cards, zero duplication.
  A family card carries its mini-tree (children + grandchildren, in-flight
  first, capped with an explicit "+N more inside"), the whole-subtree tally
  in its sub pill, and is PLACED by activity: a live root with any in-flight
  descendant sits in In Progress while keeping its own honest glyph. Family
  rows are display-only — the card click peeks the ROOT; the peek's tree is
  where you hop. Momentum stays task-level; grouped/filtered views stay
  per-task (the drill-down). Dragging a family card restages the ROOT task
  only — an escalated card's illegal drops refuse via the same fences.

  ## The deck (wave 18)

  The default view drops the status kanban entirely: status is a CHIP, not
  architecture. One horizontal snap-rail of identical phone-frame (9:19.5)
  context cards — in-flight families first, then ready, blocked, open — and
  Done is the LAST card, a single ledger phone with the honest window note.
  Cards are not draggable on the deck (there are no drop targets); a click
  EXPANDS (wave 21). The grouped/filtered kanban remains the drag/drill-down
  surface (claim, close, release all still one drop away via Group).

  ## Expand → gantt (wave 21)

  A deck card click expands the card in place into its family timeline: the
  list becomes the chart — the same rows as the left column, each with a bar
  from its creation to its close (done) or to now (live), colored by state,
  the now-line on the track's right edge. `?expand=<id>` rides the URL
  beside the peek's `?task=`; a gantt row (or the details button) peeks with
  the timeline still open; × collapses.

  ## Task peek (wave 13)

  A card click opens a read-only right-hand inspector over the live board —
  the substance the card's signal can only count: the claim lease (worker,
  epoch, held-since), the description, every acceptance criterion WITH its
  close-time evidence, children (in-flight first; click to re-peek), and
  titled blockers. The peeked id rides the URL (`?task=<id>`, D14) so a peek
  is shareable and the back button closes it; Esc / × / scrim-click close;
  the panel re-derives on every realtime event and reconcile so it is as
  live as the board behind it. Reads only — every write still goes through
  the fenced drag primitives or `bp`.

  ## Context & insight (waves 14-15)

  The peek carries the task's whole neighbourhood. Wave 15 renders it as ONE
  FAMILY TREE: the ancestor spine (root goal → … → this task, walked over the
  board corpus, cycle-safe, dead parents as inert rows), the SIBLINGS at
  every spine level (the task's siblings AND the parent's siblings — any
  shared real parent groups rows; nil-parent roots never do), and the focused
  task's descendant subtree (children, grandchildren, … — depth/node capped
  with explicit "+N more" rows). Every non-self row hops to re-peek. Plus the
  full-subtree rollup in the Tree header, the REVERSE dependency list (what
  this task blocks — the impact read), and an Activity log off the durable
  `mutation_events` rows (claimed/closed/relabeled/lease-expired, with the
  acting worker from each event's document snapshot) ending at `created`.
  """

  use BarkparkWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Content.Scope
  alias Barkpark.Repo
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Board
  alias Barkpark.Tasks.Edge
  alias Barkpark.Tenancy

  # The slow reconcile cadence. Realtime motion is instant off the broadcast;
  # this only re-derives what one event can't (ready overlay, cascade-unblocks,
  # the windowed done_today) — so seconds, not milliseconds, is right.
  @refresh_ms 15_000

  @dataset "production"

  @facet_keys [:goal, :priority, :label, :worker]

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    # NAMED COST (doctrine lever #2, query-count): `Board.snapshot/1` is the
    # heaviest read of the Studio set (load_task_docs + load_blocker_targets +
    # a full task-table projection). The disconnected (dead) mount render is
    # DISCARDED the instant the WebSocket connects and mount re-runs — and this
    # page is admin-gated, so no crawler/unfurler ever consumes that HTML.
    # Running the projection there was pure waste (2× per open). Guard it behind
    # `connected?/1`: paint an empty board skeleton on the dead render (the pure,
    # DB-free `Board.build([])`), and load the real snapshot ONCE, on connect.
    board = if connected, do: Board.snapshot(dataset: @dataset), else: Board.build([])

    # FIELD-VISIBILITY SEAL (felix W19): compute the fail-closed visibility
    # predicate ONCE per mount and thread it into every `card_from_broadcast/3`,
    # so a realtime broadcast card is gated by the SAME schema decisions as the
    # `Board.snapshot` fetched cards — WITHOUT re-resolving the schema per event.
    # On the disconnected (dead) render assign `fn _ -> false end`: no DB touch
    # (mirrors the L212 no-snapshot-on-static-render guard) and no broadcast can
    # arrive pre-connect, so fail-closed is free of behavioral cost. `:refresh`
    # recomputes it, so a schema edit self-heals within one reconcile cadence.
    readable? = if connected, do: Board.field_visibility_gate(@dataset), else: fn _ -> false end

    {:ok,
     socket
     |> assign(:dataset, @dataset)
     |> assign(:loading, not connected)
     |> assign(:board, board)
     |> assign(:readable?, readable?)
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
    socket =
      socket
      |> assign(:group_by, parse_group(params["group"]))
      |> assign(:filters, parse_filters(params))

    # `handle_params` runs on the DISCARDED disconnected render too, and
    # `assign_peek/2` issues a FRESH per-task doc read (`load_peek`). Skip that
    # DB touch on the dead render for the same reason as the mount snapshot —
    # `handle_params` re-runs on connect (with the real board) and loads the
    # peek/expand for real then. Cheap param parsing above always runs.
    socket =
      if connected?(socket) do
        socket
        |> assign_peek(params["task"])
        |> assign_expanded(params["expand"])
      else
        socket |> assign(:peek, nil) |> assign(:expanded, nil)
      end

    {:noreply, assign_view(socket)}
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
      card = Board.card_from_broadcast(doc, prev, socket.assigns.readable?)
      {board, change} = Board.apply_change(board, card)

      {:noreply,
       socket
       |> assign(:board, board)
       |> assign(:last_change, change)
       |> update(:seen, &MapSet.put(&1, key))
       |> refresh_peek()
       |> assign_view()}
    end
  end

  # Slow reconcile: a full snapshot re-derives the ready overlay + cascade
  # unblocks + the windowed done_today that a single optimistic event cannot,
  # and resets the done_today baseline to the authoritative value. Clear the
  # last flash so a stale marker doesn't linger, and reschedule.
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    # Recompute the visibility predicate alongside the snapshot (felix W19): a
    # schema edit made after mount self-heals into the realtime path within one
    # reconcile cadence, never per broadcast.
    {:noreply,
     socket
     |> assign(:board, Board.snapshot(dataset: socket.assigns.dataset))
     |> assign(:readable?, Board.field_visibility_gate(socket.assigns.dataset))
     |> assign(:last_change, nil)
     |> refresh_peek()
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

  # ── wave 13: the task peek panel ────────────────────────────────────────────
  #
  # A card click opens a right-hand inspector over the live board; the peeked
  # task rides the URL (`?task=<id>`, D14 — shareable, back-button closes) so
  # handle_params stays the single mutation path. A hop (child/blocker row)
  # re-peeks in place; × / Esc / scrim-click close.
  def handle_event("peek", %{"task" => task_id}, socket) when is_binary(task_id) do
    {:noreply, patch_to(socket, socket.assigns.group_by, socket.assigns.filters, task_id)}
  end

  def handle_event("peek-close", _params, socket) do
    {:noreply, patch_to(socket, socket.assigns.group_by, socket.assigns.filters, nil)}
  end

  # ── wave 21: expand a phone into its GANTT ──────────────────────────────────
  #
  # A deck card click widens the card in place into a family timeline (the
  # list stays as the left column; bars run created → closed/now). The
  # expanded id rides the URL (`?expand=<id>`, D14) beside the peek's
  # `?task=` — a gantt row click peeks that task with the gantt still open.
  def handle_event("expand", %{"task" => task_id}, socket) when is_binary(task_id) do
    {:noreply,
     patch_to(
       socket,
       socket.assigns.group_by,
       socket.assigns.filters,
       socket.assigns.peek && socket.assigns.peek.doc_id,
       task_id
     )}
  end

  # × collapses to a QUIET deck — the explicit "none" sentinel, because the
  # bare URL means "default" and the default auto-expands in-flight cards.
  def handle_event("expand-close", _params, socket) do
    {:noreply,
     patch_to(
       socket,
       socket.assigns.group_by,
       socket.assigns.filters,
       socket.assigns.peek && socket.assigns.peek.doc_id,
       "none"
     )}
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

      # PDS-D289 refuses a `done` close over unmet acceptance criteria. Saying
      # "its claim moved under you" here would be the exact defect this wave
      # exists to kill — a message that names the wrong cause. The board has no
      # override affordance (that needs a reason, and a drag has nowhere to type
      # one), so it says what happened and where to fix it.
      {:error, {:criteria_unmet, indices}} ->
        {:noreply,
         rollback(
           socket,
           "Couldn't mark that done — acceptance " <>
             criteria_word(indices) <>
             " #{Enum.join(indices, ", ")} (0-based) #{plural_verb(indices)} not met yet. " <>
             "Stamp them with evidence first, or close it from the CLI with a recorded reason."
         )}

      # PDS-D291 refuses a `done` close of a criteria-less row whose reason names
      # no artifact. A DRAG can never satisfy it: the board sends no reason at
      # all, so the honest message is that this row cannot be finished by
      # dragging — not the catch-all's "its claim moved under you", which names a
      # cause that did not happen and sends the reader to re-claim for nothing.
      {:error, :close_reason_needs_artifact} ->
        {:noreply,
         rollback(
           socket,
           "Couldn't mark that done — this task names no acceptance criteria, so a close " <>
             "has to name the PR + sha (or paste the run) that discharged it. Add criteria " <>
             "and stamp them, or close it from the CLI with that reason."
         )}

      {:error, _} ->
        {:noreply, rollback(socket, "Couldn't close that task — its claim moved under you.")}
    end
  end

  # A voluntary UNCLAIM (wave 17) — the holder drops their own in-flight card
  # back on Open. Optimistic move to open (worker cleared so the card stops
  # painting their name), then the fenced release; a refused fence (lease
  # moved under you) rolls back to the authoritative snapshot.
  defp run_restage(socket, {:release}, ctx) do
    socket = optimistic_move(socket, ctx.prev, "open", nil)

    case Tasks.release(ctx.task_id, ctx.worker, observed_epoch: ctx.epoch) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, rollback(socket, "Couldn't release that task — its claim moved under you.")}
    end
  end

  # No legal transition: never touch the model, never call a primitive — just
  # surface WHY (the card stays where the server last rendered it; the hook does
  # not reorder the DOM optimistically, so nothing needs snapping back).
  defp run_restage(socket, :refuse, ctx) do
    {:noreply,
     assign(socket, :notice, refuse_notice(ctx.from_col, ctx.to_col, ctx.holder, ctx.worker))}
  end

  # Wording helpers for the criteria-unmet refusal above. They live AFTER the
  # last run_restage/3 clause on purpose: sitting between two clauses of the
  # same name and arity is a --warnings-as-errors build failure.
  defp criteria_word([_one]), do: "criterion"
  defp criteria_word(_many), do: "criteria"
  defp plural_verb([_one]), do: "is"
  defp plural_verb(_many), do: "are"

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

      to_col == :open and from_col == :in_progress ->
        "@#{holder} holds this task — only the holder can release it back to Open."

      to_col == :open ->
        "Only an in-flight task can be dropped on Open (that releases the claim)."

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

  # ── wave 13: peek loading ───────────────────────────────────────────────────

  # Parse-and-load the `?task=` param into @peek. nil/blank closes; an unknown
  # id peeks nothing (no crash, no panel — the board is unchanged).
  defp assign_peek(socket, task_id) when is_binary(task_id) and task_id != "" do
    assign(socket, :peek, load_peek(task_id, socket.assigns.board))
  end

  defp assign_peek(socket, _), do: assign(socket, :peek, nil)

  # Re-derive the open peek after the board model moved (a realtime event or
  # the :refresh reconcile) so the panel is as live as the board behind it.
  defp refresh_peek(socket) do
    case socket.assigns[:peek] do
      %{doc_id: doc_id} -> assign(socket, :peek, load_peek(doc_id, socket.assigns.board))
      _ -> socket
    end
  end

  # The full human projection of one task: a FRESH doc read (description,
  # criteria with evidence, the claim lease) + the board's own cards for
  # children (same corpus the columns paint) + a titled blocker list off the
  # blocks-edges. Reads only — the panel writes nothing.
  defp load_peek(task_id, board) do
    case peek_doc(task_id) do
      %Document{} = doc ->
        content = doc.content || %{}
        lid = Content.published_id(doc.doc_id)
        card = board.cards_by_id[lid]
        ancestors = peek_ancestors(board, Map.get(content, "parent_id"))
        subtree = peek_subtree(board, lid)

        # Field-visibility seal: this panel hand-picks content fields straight
        # off the raw doc, so — unlike the sanctioned `tasks/query.ex` read path —
        # nothing here rides `Envelope.render`. Resolve the SAME task schema ONCE
        # and gate every hand-picked field through the shared visibility predicate
        # as an ANONYMOUS, fail-closed caller (mirrors `tasks/query.ex`
        # measure_field_readable?/2). A field the schema declares private /
        # owner_only / readable_by is redacted to its empty value so this ungated
        # board mount can never leak it; an undeclared field stays public (legacy
        # parity). No task field declares visibility today — fail-closed
        # hardening, not a behavior change.
        schema = peek_schema()
        readable? = fn field -> peek_field_readable?(schema, field) end
        # nil = SEALED (schema-private field — the section never renders, no
        # empty shell hints it exists); [] = authored-empty (the criteria-first
        # reader shows its honest empty state).
        criteria = if(readable?.("acceptance_criteria"), do: peek_criteria(content), else: nil)
        blockers = peek_blockers(doc.id)
        blocks = peek_blocks(doc.id)
        # The purpose dossier hand-picks content fields itself (purpose, priority,
        # parent_id, …), so it rides the SAME seal: unreadable fields are dropped
        # from its input before it derives anything.
        sealed_content = content |> Enum.filter(fn {k, _} -> readable?.(k) end) |> Map.new()

        %{
          doc_id: lid,
          title: doc.title,
          col: card && card.col,
          lifecycle_status: Map.get(content, "lifecycle_status") || "open",
          priority: if(readable?.("priority"), do: Map.get(content, "priority")),
          parent_id: if(readable?.("parent_id"), do: Map.get(content, "parent_id")),
          labels: if(readable?.("labels"), do: (card && card.labels) || [], else: []),
          github: card && card.github,
          claim: if(readable?.("claim"), do: peek_claim(content)),
          description:
            if(readable?.("description"), do: presence(Map.get(content, "description"))),
          design_doc: if(readable?.("design_doc"), do: presence(Map.get(content, "design_doc"))),
          criteria: criteria,
          ancestors: ancestors,
          subtree: subtree,
          tree: peek_tree(board, lid, ancestors, subtree),
          purpose:
            peek_purpose(
              sealed_content,
              doc.title,
              card,
              ancestors,
              criteria || [],
              blockers,
              blocks
            ),
          blockers: blockers,
          blocks: blocks,
          events: if(readable?.("events"), do: peek_events(lid), else: []),
          created_at: doc.inserted_at,
          updated_at: doc.updated_at
        }

      _ ->
        nil
    end
  end

  # The same exact/`drafts.` fallback the restage fresh-read uses, dataset-
  # scoped, published row preferred, NEVER interpolated (a crafted ?task= is
  # only ever a bind parameter).
  defp peek_doc(task_id) do
    case fetch_peek_doc(task_id) do
      %Document{} = doc ->
        doc

      nil ->
        if String.starts_with?(task_id, "drafts."),
          do: nil,
          else: fetch_peek_doc("drafts." <> task_id)
    end
  end

  defp fetch_peek_doc(doc_id) do
    Repo.one(
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task" and d.dataset == ^@dataset,
        limit: 1
      )
    )
  end

  # Resolve the task schema for the peek field-visibility cross-check,
  # dataset-scoped to the board's own `@dataset` (mirrors `tasks/query.ex`
  # load_task_schema/3). nil on miss ⇒ every field undeclared ⇒ public (legacy
  # parity), never a crash. One indexed `Repo.one` per peek open/refresh.
  defp peek_schema do
    case Content.get_schema("task", @dataset, []) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  # ANONYMOUS + fail-closed field-visibility check (mirrors `tasks/query.ex`
  # measure_field_readable?/2). A declared private / owner_only / readable_by
  # field is denied to the ungated board viewer; an undeclared field is public.
  defp peek_field_readable?(schema, field) do
    Barkpark.Content.Envelope.field_readable?(
      schema,
      field,
      Barkpark.Content.CallerContext.anonymous()
    )
  end

  defp peek_claim(content) do
    case Map.get(content, "claim") do
      %{"worker" => worker} = claim when is_binary(worker) and worker != "" ->
        %{worker: worker, epoch: claim["epoch"], at: parse_ts(claim["ts_iso"])}

      _ ->
        nil
    end
  end

  defp parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil

  # Criteria with their texts + close-time evidence — the data the card's n/m
  # can only count. A malformed entry degrades to a positional placeholder.
  defp peek_criteria(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) ->
        list
        |> Enum.with_index(1)
        |> Enum.map(fn
          {%{} = entry, i} ->
            %{
              text: presence(entry["criterion"]) || "criterion #{i}",
              met: entry["met"] == true,
              evidence: presence(entry["evidence"])
            }

          {_other, i} ->
            %{text: "criterion #{i}", met: false, evidence: nil}
        end)

      _ ->
        []
    end
  end

  # Purpose is an explicit task dossier when authored and an honest, labelled
  # projection when an older task has not been migrated yet. Readers should
  # never need to infer why a task exists from a wall of prose.
  defp peek_purpose(content, title, card, ancestors, criteria, blockers, blocks) do
    raw = Map.get(content, "purpose")
    authored = is_map(raw)
    raw = if authored, do: raw, else: %{}
    goal = List.first(ancestors)
    parent = List.last(ancestors)
    goal_name = goal && (goal.title || goal.doc_id)
    parent_name = parent && (parent.title || parent.doc_id)
    priority = Map.get(content, "priority")

    %{
      authored: authored,
      part_of:
        presence(raw["part_of"]) ||
          parent_name ||
          presence(Map.get(content, "parent_id")) || "Standalone task",
      impact:
        presence(raw["impact"]) || "blocks #{length(blocks)} · blocked by #{length(blockers)}",
      statement: presence(raw["statement"]) || presence(title) || "Complete this task",
      why:
        presence(raw["why"]) ||
          derived_purpose_why(goal_name, parent_name),
      endgame:
        presence(raw["endgame"]) ||
          derived_purpose_endgame(criteria, parent_name),
      importance:
        purpose_score(raw["importance"], importance_score(priority), importance_reason(priority)),
      relevance:
        purpose_score(
          raw["relevance"],
          relevance_score(content, card),
          "derived from current task context"
        ),
      proof: purpose_proof(raw["proof"], criteria, content, title)
    }
  end

  defp first_criterion([%{text: text} | _]), do: presence(text)
  defp first_criterion(_), do: nil

  defp derived_purpose_why(goal_name, parent_name)
       when is_binary(goal_name) and is_binary(parent_name) and goal_name != parent_name do
    "Why this task is necessary for #{parent_name} within #{goal_name} is not recorded"
  end

  defp derived_purpose_why(_goal_name, parent_name) when is_binary(parent_name) do
    "Why this task is necessary to achieve #{parent_name} is not recorded"
  end

  defp derived_purpose_why(_goal_name, _parent_name) do
    "Why this task is worth doing is not recorded"
  end

  defp derived_purpose_endgame(_criteria, parent_name) when is_binary(parent_name) do
    "Advance #{parent_name} by completing this task"
  end

  defp derived_purpose_endgame(criteria, _parent_name) when criteria != [] do
    "Meet all #{length(criteria)} acceptance criteria and close the task"
  end

  defp derived_purpose_endgame([], _parent_name) do
    "Define acceptance criteria, then complete the task"
  end

  defp importance_reason(nil), do: "default score; no priority is recorded"
  defp importance_reason(priority), do: "derived from P#{priority} queue priority"

  defp purpose_score(%{} = raw, fallback, fallback_reason) do
    %{
      score: clamp_score(raw["score"], fallback),
      reason: presence(raw["reason"]) || fallback_reason
    }
  end

  defp purpose_score(_, fallback, reason), do: %{score: fallback, reason: reason}

  defp clamp_score(score, _fallback) when is_integer(score), do: min(100, max(0, score))
  defp clamp_score(score, fallback) when is_float(score), do: clamp_score(round(score), fallback)
  defp clamp_score(_, fallback), do: fallback

  defp importance_score(0), do: 100
  defp importance_score(1), do: 90
  defp importance_score(2), do: 75
  defp importance_score(3), do: 55
  defp importance_score(4), do: 35
  defp importance_score(_), do: 50

  defp relevance_score(content, card) do
    cond do
      Map.get(content, "lifecycle_status") == "in_progress" -> 90
      presence(Map.get(content, "design_doc")) -> 65
      card && card.parent_id -> 60
      true -> 50
    end
  end

  defp purpose_proof(list, _criteria, _content, _title) when is_list(list) and list != [] do
    Enum.flat_map(list, fn
      %{} = item ->
        evidence = presence(item["evidence"])

        if evidence do
          [
            %{
              claim: presence(item["claim"]) || "Purpose evidence",
              evidence: evidence,
              source: presence(item["source"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp purpose_proof(_, criteria, content, title) do
    criterion = first_criterion(criteria)

    [
      presence(title) && %{claim: "Task identity", evidence: title, source: "document.title"},
      criterion &&
        %{claim: "Completion is testable", evidence: criterion, source: "acceptance_criteria"},
      presence(Map.get(content, "parent_id")) &&
        %{
          claim: "Parent relationship",
          evidence: Map.get(content, "parent_id"),
          source: "parent_id"
        }
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Status order for tree rows — in-flight first so the active work leads.
  @peek_child_order [:in_progress, :ready, :open, :blocked, :done]

  # Family-tree caps: siblings shown per level, descendant depth below the
  # focused task, and a global descendant node budget. Every truncation emits
  # an explicit "+N more" row — never silent.
  @tree_sibling_cap 8
  @tree_desc_depth 3
  @tree_desc_cap 30

  # ── the family tree (wave 15) ───────────────────────────────────────────────
  #
  # One flat, depth-annotated node list covering the task's WHOLE family:
  # the spine (root ancestor → … → this task), every spine node's children —
  # which is exactly "the parent's siblings" and "the task's siblings" — and
  # the focused task's full descendant subtree (children, grandchildren, …).
  # Only spine nodes descend; siblings render as single hoppable rows; every
  # cap truncation is an explicit "+N more" row (never silent). Root-level
  # peers (nil parent) are NOT siblings — only a shared REAL parent groups
  # rows.
  defp peek_tree(board, lid, ancestors, subtree) do
    index = children_index(board)
    spine = Enum.map(ancestors, & &1.doc_id) ++ [lid]
    tree_spine(board, index, spine, lid, 0, subtree_total(subtree), [])
  end

  defp subtree_total(%{total: total}), do: total
  defp subtree_total(_), do: 0

  defp children_index(board) do
    board.cards_by_id
    |> Map.values()
    |> Enum.filter(&is_binary(&1.parent_id))
    |> Enum.group_by(& &1.parent_id)
  end

  defp sorted_children(index, id) do
    order = @peek_child_order |> Enum.with_index() |> Map.new()

    index
    |> Map.get(id, [])
    |> Enum.sort_by(fn c -> {Map.get(order, c.col, 99), c.title || c.doc_id} end)
  end

  # Walk the spine. The LAST spine node is the focused task: emit it, then its
  # capped descendant subtree. An inner spine node emits itself, then all its
  # children in order — recursing INLINE when the child is the next spine node
  # so the deeper family lands in document order.
  defp tree_spine(board, index, [id], lid, depth, subtree_total, acc) do
    acc = acc ++ [tree_node(board, id, depth, lid)]
    {desc, emitted} = tree_desc(board, index, id, depth + 1, @tree_desc_depth, {[], 0})
    acc = acc ++ desc

    case max(subtree_total - emitted, 0) do
      0 -> acc
      hidden -> acc ++ [%{kind: :more, count: hidden, depth: depth + 1}]
    end
  end

  defp tree_spine(board, index, [id, next | rest], lid, depth, subtree_total, acc) do
    acc = acc ++ [tree_node(board, id, depth, lid)]
    children = sorted_children(index, id)
    {shown, extra} = cap_siblings(children, next)

    acc =
      Enum.reduce(shown, acc, fn child, a ->
        if child.doc_id == next do
          tree_spine(board, index, [next | rest], lid, depth + 1, subtree_total, a)
        else
          a ++ [tree_node(board, child.doc_id, depth + 1, lid)]
        end
      end)

    case extra do
      0 -> acc
      n -> acc ++ [%{kind: :more, count: n, depth: depth + 1}]
    end
  end

  # Cap a sibling row, but NEVER cap away the spine child — the lineage always
  # renders even when it sorts past the window.
  defp cap_siblings(children, spine_id) do
    shown = Enum.take(children, @tree_sibling_cap)

    shown =
      if Enum.any?(shown, &(&1.doc_id == spine_id)) do
        shown
      else
        spine_child = Enum.find(children, &(&1.doc_id == spine_id))
        Enum.take(shown, @tree_sibling_cap - 1) ++ Enum.reject([spine_child], &is_nil/1)
      end

    {shown, max(length(children) - length(shown), 0)}
  end

  # The focused task's descendants — depth-capped, node-budgeted DFS so the
  # tree shows children, grandchildren, … without unbounded growth.
  defp tree_desc(_board, _index, _id, _depth, 0, state), do: state

  defp tree_desc(board, index, id, depth, depth_left, {acc, n}) do
    Enum.reduce(sorted_children(index, id), {acc, n}, fn child, {a, c} ->
      if c >= @tree_desc_cap do
        {a, c}
      else
        a = a ++ [tree_node(board, child.doc_id, depth, nil)]
        tree_desc(board, index, child.doc_id, depth + 1, depth_left - 1, {a, c + 1})
      end
    end)
  end

  defp tree_node(board, id, depth, lid) do
    case board.cards_by_id[id] do
      nil ->
        %{
          kind: :node,
          doc_id: id,
          title: nil,
          role: :open,
          glyph: "○",
          worker: nil,
          sub: nil,
          depth: depth,
          self: id == lid,
          missing: true
        }

      card ->
        %{
          kind: :node,
          doc_id: id,
          title: card.title,
          role: card.color_role,
          glyph: glyph_text(card),
          worker: card.worker,
          sub: card[:sub],
          depth: depth,
          self: id == lid,
          missing: false
        }
    end
  end

  # Titled blockers off the blocks-edges (the card only carries statuses).
  defp peek_blockers(pk) do
    from(e in Edge,
      join: t in Document,
      on: t.id == e.to_id,
      where: e.from_id == ^pk and e.kind == "blocks",
      select: %{doc_id: t.doc_id, title: t.title, content: t.content}
    )
    |> Repo.all()
    |> Enum.map(fn b ->
      %{
        doc_id: Content.published_id(b.doc_id),
        title: b.title,
        lifecycle_status: Map.get(b.content || %{}, "lifecycle_status") || "open"
      }
    end)
  end

  # The ancestor chain, ROOT-FIRST — walked over the board's own cards via
  # parent_id, cycle-safe (seen-set) and depth-capped. A parent that is not on
  # the board (cancelled / foreign) terminates the walk as a dead crumb so the
  # lineage is never silently truncated.
  @ancestor_cap 6
  defp peek_ancestors(board, parent_id) do
    walk_ancestors(board, parent_id, MapSet.new(), [])
  end

  defp walk_ancestors(_board, nil, _seen, acc), do: acc
  defp walk_ancestors(_board, parent_id, _seen, acc) when not is_binary(parent_id), do: acc

  defp walk_ancestors(board, parent_id, seen, acc) do
    cond do
      MapSet.member?(seen, parent_id) or MapSet.size(seen) >= @ancestor_cap ->
        acc

      card = board.cards_by_id[parent_id] ->
        walk_ancestors(board, card.parent_id, MapSet.put(seen, parent_id), [
          %{doc_id: parent_id, title: card.title, missing: false} | acc
        ])

      true ->
        [%{doc_id: parent_id, title: nil, missing: true} | acc]
    end
  end

  # The FULL descendant rollup (BFS over the board corpus) — total and done
  # across every level, not just direct children. nil when childless.
  defp peek_subtree(board, lid) do
    by_parent =
      board.cards_by_id
      |> Map.values()
      |> Enum.filter(&is_binary(&1.parent_id))
      |> Enum.group_by(& &1.parent_id)

    case collect_subtree(by_parent, [lid], MapSet.new([lid]), []) do
      [] -> nil
      cards -> %{total: length(cards), done: Enum.count(cards, &(&1.lifecycle_status == "done"))}
    end
  end

  defp collect_subtree(_by_parent, [], _seen, acc), do: acc

  defp collect_subtree(by_parent, [id | rest], seen, acc) do
    children =
      by_parent
      |> Map.get(id, [])
      |> Enum.reject(fn c -> MapSet.member?(seen, c.doc_id) end)

    seen = Enum.reduce(children, seen, fn c, s -> MapSet.put(s, c.doc_id) end)
    collect_subtree(by_parent, Enum.map(children, & &1.doc_id) ++ rest, seen, children ++ acc)
  end

  # The REVERSE dependency read — every task whose blocks-edge names this one:
  # the work waiting on it. The impact half `blocker_statuses` can't show.
  defp peek_blocks(pk) do
    from(e in Edge,
      join: t in Document,
      on: t.id == e.from_id,
      where: e.to_id == ^pk and e.kind == "blocks",
      select: %{doc_id: t.doc_id, title: t.title, content: t.content}
    )
    |> Repo.all()
    |> Enum.map(fn b ->
      %{
        doc_id: Content.published_id(b.doc_id),
        title: b.title,
        lifecycle_status: Map.get(b.content || %{}, "lifecycle_status") || "open"
      }
    end)
  end

  # The task's recent history off the durable mutation_events log (newest
  # first, both draft/published twins). Each row projects to a friendly kind
  # plus the acting worker read from the event's document snapshot.
  @event_window 12
  defp peek_events(lid) do
    from(e in MutationEvent,
      where: e.doc_id in ^[lid, "drafts." <> lid] and e.dataset == ^@dataset,
      order_by: [desc: e.inserted_at],
      limit: @event_window,
      select: %{mutation: e.mutation, document: e.document, at: e.inserted_at}
    )
    |> Repo.all()
    |> Enum.map(fn e ->
      %{kind: event_label(e.mutation), worker: event_worker(e.mutation, e.document), at: e.at}
    end)
  end

  defp event_label("task." <> rest), do: String.replace(rest, "_", " ")
  defp event_label(other) when is_binary(other), do: other
  defp event_label(_), do: "event"

  defp event_worker("task.closed", doc) when is_map(doc) do
    get_in(doc, ["content", "claim", "closed_by"]) || get_in(doc, ["content", "claim", "worker"])
  end

  defp event_worker(_kind, doc) when is_map(doc) do
    get_in(doc, ["content", "claim", "worker"]) || get_in(doc, ["content", "assignee"])
  end

  defp event_worker(_kind, _doc), do: nil

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  # Status-string → §1 role/glyph, whitelisted (never String.to_atom/1 on
  # stored content). The peeked card's derived :col wins when it is on the
  # board (it carries the ready overlay a raw lifecycle read can't).
  @peek_roles %{
    "open" => :open,
    "in_progress" => :in_progress,
    "blocked" => :blocked,
    "done" => :done,
    "cancelled" => :cancelled,
    "considering" => :considering,
    "researching" => :researching
  }

  # The FAIL-OPEN DIM default (TLV charter D14). This used to answer `:open` for
  # anything unrecognised, so a peeked considering task — and any status a future
  # build writes — rendered as a bright, claimable backlog ○: the surface
  # reporting work that does not exist. `:unknown` is visible and neutral.
  defp safe_role(status), do: Map.get(@peek_roles, status, :unknown)

  defp peek_role(%{col: col}) when is_atom(col) and not is_nil(col), do: col
  defp peek_role(peek), do: safe_role(peek.lifecycle_status)

  defp peek_state_label(peek),
    do: peek |> peek_role() |> Atom.to_string() |> String.replace("_", " ")

  defp role_glyph(:in_progress), do: ""
  defp role_glyph(role), do: Board.glyphs()[role] || Board.glyphs()[:unknown]

  # push_patch to the URL encoding this (group, filters, peeked task) triple —
  # the ONLY mutation path (D14). The bare path when nothing is selected keeps
  # a clean, shareable URL. Group/filter events preserve the open peek; the
  # 3-arity form sets/clears it.
  defp patch_to(socket, group_by, filters) do
    patch_to(socket, group_by, filters, socket.assigns.peek && socket.assigns.peek.doc_id)
  end

  defp patch_to(socket, group_by, filters, task_id) do
    patch_to(socket, group_by, filters, task_id, socket.assigns[:expanded])
  end

  defp patch_to(socket, group_by, filters, task_id, expand_id) do
    case board_query(group_by, filters, task_id, expand_id) do
      [] -> push_patch(socket, to: ~p"/admin/projects")
      query -> push_patch(socket, to: ~p"/admin/projects?#{query}")
    end
  end

  defp board_query(group_by, filters, task_id, expand_id) do
    group_params = if group_by == :none, do: [], else: [{"group", Atom.to_string(group_by)}]

    facet_params =
      for key <- @facet_keys, vals = Map.get(filters, key, []), vals != [] do
        {Atom.to_string(key), Enum.join(vals, ",")}
      end

    peek_params = if is_binary(task_id) and task_id != "", do: [{"task", task_id}], else: []

    expand_params =
      if is_binary(expand_id) and expand_id != "", do: [{"expand", expand_id}], else: []

    group_params ++ facet_params ++ peek_params ++ expand_params
  end

  # The expanded phone's id — presence-validated only (it is compared against
  # card doc_ids, never interpolated anywhere).
  defp assign_expanded(socket, expand_id) when is_binary(expand_id) and expand_id != "",
    do: assign(socket, :expanded, expand_id)

  defp assign_expanded(socket, _), do: assign(socket, :expanded, nil)

  # Dead-render skeleton (first-paint tradeoff acknowledged, task
  # task-d8970b41d745e066): the disconnected mount no longer runs
  # `Board.snapshot/1`, so it has no cards to paint. Rather than flash the empty
  # "pipeline clear" hero (which would falsely read as "no work"), paint a light,
  # self-contained loading state; the connected mount (~one RTT later) replaces
  # it with the real board. CSP-safe, no JS, no external assets.
  @impl true
  def render(%{loading: true} = assigns) do
    ~H"""
    <style>
      .bp-loading {
        flex: 1 1 auto; min-height: 0;
        display: flex; align-items: center; justify-content: center;
        font-family: var(--font, 'Inter', -apple-system, sans-serif);
        color: var(--muted-text);
      }
      .bp-loading-inner { display: flex; align-items: center; gap: 10px; font-size: 14px; }
      .bp-loading-dot {
        width: 8px; height: 8px; border-radius: 999px; background: var(--primary);
        animation: bp-loading-pulse 1s ease-in-out infinite;
      }
      @keyframes bp-loading-pulse { 0%, 100% { opacity: 0.25; } 50% { opacity: 1; } }
      @media (prefers-reduced-motion: reduce) { .bp-loading-dot { animation: none; opacity: 0.6; } }
    </style>
    <div class="bp-page bp-loading" data-test-id="board-loading">
      <div class="bp-loading-inner"><span class="bp-loading-dot"></span> Loading board…</div>
    </div>
    """
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
      /* ── settled lanes / settled board (wave 11) ────────────────────────
         A group whose every task is done has NO pipeline — five columns of
         nothing is clutter, not information. A settled lane collapses to a
         one-line receipt (✓ label · all N done · last age) that expands to
         its done ledger; a fully-settled flat board swaps the column skeleton
         for a "pipeline clear" state. Native <details>: CSP-safe, no JS. */
      .bp-lane--settled { margin: 0 0 10px; }
      .bp-lane--settled > summary {
        display: flex; align-items: center; gap: 10px;
        padding: 9px 14px; cursor: pointer; user-select: none; list-style: none;
        border: 1px solid var(--border); border-radius: 10px;
        background: color-mix(in srgb, var(--muted-surface) 55%, transparent);
        font-size: 13px; color: var(--muted-text);
        transition: border-color 120ms ease, color 120ms ease;
      }
      .bp-lane--settled > summary:hover { color: var(--text); border-color: var(--ring); }
      .bp-lane--settled > summary::-webkit-details-marker { display: none; }
      .bp-lane--settled > summary::after {
        content: "\25B8"; font-size: 10px; color: var(--muted-text);
        transition: transform 140ms ease;
      }
      .bp-lane--settled[open] > summary::after { transform: rotate(90deg); }
      .bp-settled-label { font-weight: 600; color: var(--text); }
      .bp-settled-tally { font-variant-numeric: tabular-nums; }
      .bp-lane--settled > summary .bp-age { line-height: 1.2; }
      .bp-ledger {
        display: flex; flex-direction: column; gap: 6px;
        max-width: 560px; margin: 8px 0 4px;
      }
      .bp-settled {
        flex: 1 1 auto; min-height: 0; overflow-y: auto;
        display: flex; flex-direction: column; align-items: center;
        padding: 30px 16px 16px;
      }
      .bp-settled-hero { text-align: center; margin: 0 0 20px; }
      .bp-settled-glyph.gi { display: block; width: auto; font-size: 26px; margin: 0 0 8px; }
      .bp-settled-h {
        margin: 0; font-size: 16px; font-weight: 600;
        letter-spacing: -0.01em; color: var(--text);
      }
      .bp-settled-sub {
        margin: 6px 0 0; font-size: 13px; color: var(--muted-text); max-width: 52ch;
      }
      .bp-settled-sub code {
        font-size: 12px; background: var(--muted-surface);
        border-radius: 5px; padding: 1px 6px;
      }
      .bp-settled .bp-ledger { width: min(560px, 100%); margin: 0; }
      .bp-settled .bp-more { flex: 0 0 auto; }

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
      /* Done is a LEDGER, not competition for the eye: each entry compacts to
         one line (✓ title · age) at reduced weight, so finished work reads as
         history while the active pipeline keeps the visual budget. */
      .bp-card--done { opacity: 0.6; padding: 6px 10px; }
      .bp-card--done .bp-card-top { align-items: center; }
      .bp-card--done .bp-title {
        font-weight: 400; font-size: 12px; white-space: nowrap;
        overflow: hidden; text-overflow: ellipsis;
      }

      /* Status accent — a 2px left edge on the two states that need attention
         (working / stuck) so the board scans by column AND by card. */
      .bp-card--in_progress { border-left: 2px solid var(--info); }
      .bp-card--blocked { border-left: 2px solid var(--warn); }

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
        flex: 1 1 auto; min-width: 0;
        font-weight: 500; font-size: 13px; line-height: 1.4; color: var(--text);
      }
      /* Freshness stamp — every card dates itself (relative, tabular) so
         relevance is readable at a glance without opening anything. */
      .bp-age {
        flex: 0 0 auto; margin-left: auto; padding-left: 8px;
        font-size: 11px; color: var(--muted-text);
        font-variant-numeric: tabular-nums; line-height: 1.6; opacity: 0.8;
      }
      .bp-meta {
        display: flex; flex-wrap: wrap; gap: 5px 6px;
        margin-top: 8px; font-size: 11px; align-items: center;
        color: var(--muted-text);
      }
      .bp-pip, .bp-goal, .bp-label {
        padding: 1.5px 7px; border-radius: 5px; line-height: 1.5;
        font-variant-numeric: tabular-nums; white-space: nowrap;
      }
      .bp-pip { background: var(--muted-surface); color: var(--muted-text); font-weight: 600; }
      .bp-pip[data-priority="0"] { background: var(--danger-soft); color: var(--danger); }
      .bp-pip[data-priority="1"] { background: var(--warn-soft); color: var(--warn); }
      .bp-goal { background: var(--info-soft); color: var(--info); }
      .bp-goal::before { content: "↳ "; opacity: 0.7; }
      .bp-label { background: var(--muted-surface); color: var(--muted-text); }
      .bp-label--more { opacity: 0.75; }
      /* The holder anchors the row's right edge and ellipsizes rather than
         wrapping — long worker ids never smear the card. */
      .bp-worker {
        color: var(--muted-text); margin-left: auto; padding-left: 6px;
        max-width: 15ch; overflow: hidden; text-overflow: ellipsis;
        white-space: nowrap;
      }
      .bp-worker::before { content: "@"; opacity: 0.65; }

      /* Acceptance criteria — a real progress row (track + fill + n/m), not a
         chip: the state of the work is structure, not decoration. */
      .bp-progress {
        display: flex; align-items: center; gap: 8px; margin-top: 9px;
      }
      .bp-progress-track {
        flex: 1 1 auto; height: 3px; border-radius: 999px;
        background: var(--muted-surface); overflow: hidden;
      }
      .bp-progress-fill {
        display: block; height: 100%; border-radius: 999px;
        background: var(--ok);
        transition: width 500ms cubic-bezier(0.22, 1, 0.36, 1);
      }
      .bp-crit {
        flex: 0 0 auto; font-size: 11px; font-weight: 600; color: var(--ok);
        font-variant-numeric: tabular-nums; white-space: nowrap;
      }
      .bp-crit--zero { color: var(--muted-text); font-weight: 500; }

      /* A blocked card says WHY it is stuck — the §0 always-a-next-step read. */
      .bp-block-note {
        margin: 8px 0 0; font-size: 11px; color: var(--warn);
        font-variant-numeric: tabular-nums;
      }

      /* ── focus (wave 12): what matters gets the detail ─────────────────────
         In Progress is the board's centre of gravity — a wider panel, and each
         in-flight card names the step being worked RIGHT NOW: its in-flight
         subtask (the TUI activity-focus) or the first unmet criterion. */
      .bp-board > .bp-col[data-col="in_progress"] { flex: 0 0 400px; width: 400px; }
      .bp-focus {
        display: flex; align-items: baseline; gap: 7px;
        margin: 8px 0 0; padding: 6px 9px; border-radius: 7px;
        background: var(--info-soft); font-size: 11.5px; color: var(--text);
      }
      .bp-focus-k {
        flex: 0 0 auto; font-size: 10px; font-weight: 700;
        letter-spacing: 0.08em; text-transform: uppercase; color: var(--info);
      }
      .bp-focus-t {
        flex: 1 1 auto; min-width: 0; overflow: hidden;
        text-overflow: ellipsis; white-space: nowrap;
      }
      .bp-focus-w {
        flex: 0 0 auto; color: var(--muted-text); font-size: 11px;
        max-width: 14ch; overflow: hidden; text-overflow: ellipsis;
        white-space: nowrap;
      }
      /* Subtask lineage pill — done/total children, on any card that has them. */
      .bp-sub {
        padding: 1.5px 7px; border-radius: 5px; line-height: 1.5;
        font-variant-numeric: tabular-nums; white-space: nowrap;
        background: var(--muted-surface); color: var(--muted-text);
      }
      .bp-sub--all-done { color: var(--ok); background: var(--ok-soft); }
      /* Family cards (wave 16): fewer, LARGER cards — the family's mini-tree
         lives inside the root's card, so nothing renders twice. */
      .bp-fam {
        list-style: none; margin: 9px 0 0; padding: 8px 0 0;
        border-top: 1px solid var(--border);
        display: flex; flex-direction: column; gap: 4px;
      }
      .bp-fam-row {
        display: flex; align-items: center; gap: 6px; min-width: 0;
        padding-left: calc((var(--d) - 1) * 14px);
        font-size: 12px;
      }
      .bp-fam-row .gi { font-size: 11px; }
      .bp-fam-t {
        flex: 1 1 auto; min-width: 0; color: var(--text); opacity: 0.9;
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .bp-fam-more {
        padding-left: 20px; font-size: 11px; color: var(--muted-text);
        font-variant-numeric: tabular-nums;
      }
      .bp-board[data-family] > .bp-col { flex: 0 0 380px; width: 380px; }
      .bp-board[data-family] > .bp-col[data-col="in_progress"] {
        flex: 0 0 440px; width: 440px;
      }

      /* ── the Deck (wave 18): phone-frame context cards on one rail ──────
         Status is a CHIP, not architecture: one horizontal snap-rail of
         identical 9:19.5 cards — in-flight first, then ready, blocked,
         open; Done is the LAST card (a ledger phone). The card height is
         the rail height; the aspect ratio derives the width, so every card
         is exactly one "phone". */
      .bp-deck {
        flex: 1 1 auto; min-height: 0;
        display: flex; flex-wrap: nowrap; align-items: stretch; gap: 16px;
        overflow-x: auto; overflow-y: hidden;
        padding: 4px 2px 12px;
        scroll-snap-type: x proximity;
        scrollbar-width: thin; scrollbar-color: var(--border) transparent;
      }
      .bp-deck::-webkit-scrollbar { height: 10px; }
      .bp-deck::-webkit-scrollbar-thumb { background: var(--border); border-radius: 999px; }
      .bp-phone {
        flex: 0 0 auto; height: 100%; aspect-ratio: 9 / 19.5;
        min-width: 250px; max-width: 420px;
        scroll-snap-align: start;
        display: flex; flex-direction: column; gap: 10px;
        background: var(--surface); border: 1px solid var(--border);
        border-radius: 20px; padding: 16px 15px 13px;
        overflow: hidden; cursor: pointer;
        transition: border-color 120ms ease, box-shadow 120ms ease;
      }
      .bp-phone:hover {
        border-color: color-mix(in srgb, var(--border) 45%, var(--muted-text));
        box-shadow: 0 10px 30px rgb(0 0 0 / 0.10);
      }
      .bp-phone--in_progress {
        border-color: color-mix(in srgb, var(--info) 40%, var(--border));
      }
      .bp-phone--blocked {
        border-color: color-mix(in srgb, var(--warn) 40%, var(--border));
      }
      .bp-phone-head {
        display: flex; align-items: center; gap: 7px; flex: 0 0 auto;
        font-size: 11px; color: var(--muted-text);
      }
      .bp-phone-state {
        text-transform: uppercase; letter-spacing: 0.07em;
        font-size: 10px; font-weight: 700;
      }
      .bp-phone-state.is-flight {
        color: var(--info); background: var(--info-soft);
        padding: 1px 7px; border-radius: 999px;
      }
      .bp-phone-head .bp-age { margin-left: auto; padding-left: 0; }
      .bp-phone-title {
        margin: 0; flex: 0 0 auto;
        font-size: 15px; font-weight: 600; letter-spacing: -0.01em;
        line-height: 1.35; color: var(--text);
      }
      .bp-phone-body {
        flex: 1 1 auto; min-height: 0; overflow-y: auto;
        scrollbar-width: thin; scrollbar-color: var(--border) transparent;
      }
      .bp-phone-body .bp-fam { border-top: 0; padding-top: 0; margin-top: 0; gap: 6px; }
      .bp-phone > .bp-focus { flex: 0 0 auto; margin-top: 0; }
      .bp-phone > .bp-progress { flex: 0 0 auto; margin-top: 0; }
      .bp-phone > .bp-meta {
        flex: 0 0 auto; margin-top: 0; padding-top: 9px;
        border-top: 1px solid var(--border);
      }
      .bp-phone--ledger .bp-phone-body .bp-ledger { max-width: none; margin: 0; }
      /* ── expand → gantt (wave 21): the card widens IN PLACE into a family
         timeline — the list stays as the left column, bars run created →
         closed/now. The phone aspect yields while expanded. */
      .bp-phone.is-expanded {
        aspect-ratio: auto; width: min(1000px, 80vw); max-width: none;
        cursor: default;
      }
      .bp-phone.is-expanded .bp-fam { display: none; }
      .bp-phone.is-expanded .bp-phone-desc { -webkit-line-clamp: 2; }
      .bp-x-details {
        border: 1px solid var(--border); background: transparent;
        color: var(--muted-text); font: inherit; font-size: 10.5px;
        font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase;
        border-radius: 6px; padding: 2px 8px; cursor: pointer;
        margin-left: auto;
      }
      .bp-x-details:hover { color: var(--text); border-color: var(--ring); }
      .bp-phone.is-expanded .bp-phone-head .bp-age { margin-left: 0; }
      .bp-phone.is-expanded .bp-phone-head .bp-peek-x { margin-left: 4px; }
      /* High-standard pass (wave 24): the chart reads in LAYERS — task rows
         lead (weight + breathing room), their checks tuck beneath as quiet
         single-line rows, descriptions whisper at one line. Real corpora
         write paragraph-length criteria; the chart shows four and counts the
         rest (the inline detail has them all). */
      .bp-gantt { display: flex; flex-direction: column; gap: 2px; padding-top: 4px; }
      .bp-gantt-axis {
        display: flex; justify-content: space-between;
        font-size: 10px; letter-spacing: 0.05em; text-transform: uppercase;
        color: var(--muted-text); padding-left: 42%; margin-bottom: 2px;
      }
      .bp-gantt-row {
        display: grid; grid-template-columns: 42% 1fr; gap: 2px 12px;
        align-items: center; min-width: 0;
        margin-top: 7px; padding: 2px 4px; border-radius: 8px;
        transition: background 120ms ease;
      }
      .bp-gantt-row:hover { background: color-mix(in srgb, var(--muted-surface) 60%, transparent); }
      .bp-gantt-row:first-of-type { margin-top: 0; }
      .bp-gantt-label {
        display: flex; align-items: center; gap: 6px; min-width: 0;
        border: 0; background: transparent; font: inherit; font-size: 12.5px;
        font-weight: 500; color: var(--text); text-align: left; cursor: pointer;
        padding: 3px 4px 3px calc(var(--d) * 12px + 4px); border-radius: 6px;
      }
      .bp-gantt-label:hover { background: var(--muted-surface); }
      .bp-gantt-label .bp-focus-w { max-width: 12ch; }
      .bp-gantt-label:focus-visible { outline: 2px solid var(--ring); outline-offset: 1px; }
      .bp-gantt-t {
        flex: 1 1 auto; min-width: 0; overflow: hidden;
        text-overflow: ellipsis; white-space: nowrap;
      }
      .bp-gantt-track {
        position: relative; height: 12px; border-radius: 999px;
        background: var(--muted-surface);
        border-right: 2px solid color-mix(in srgb, var(--muted-text) 55%, transparent);
      }
      .bp-gantt-bar {
        position: absolute; top: 2px; bottom: 2px; border-radius: 999px;
        background: var(--muted-text); opacity: 0.55;
      }
      .bp-gantt-bar.is-in_progress { background: var(--info); opacity: 1; }
      .bp-gantt-bar.is-done { background: var(--ok); opacity: 0.9; }
      .bp-gantt-bar.is-blocked { background: var(--warn); opacity: 0.9; }
      .bp-gantt-bar.is-ready { background: var(--muted-text); opacity: 0.75; }
      /* Wave 22: ACTIVE gantt rows keep the list's readability — the ongoing
         task's brief + checklist span under its bar line. */
      .bp-gantt-detail {
        grid-column: 1 / -1; min-width: 0;
        padding: 0 8px 2px calc(var(--d) * 12px + 24px);
      }
      .bp-gantt-detail .bp-fam-desc {
        margin: 0 0 2px; padding-left: 0; -webkit-line-clamp: 1;
        font-size: 11px; opacity: 0.85;
      }
      .bp-gantt-detail .bp-crits--row { margin: 0; padding-left: 0; }
      /* Wave 24: criteria as HORIZONTAL POINTS — a premium flex strip of
         check chips under the task: met chips lit, the NEXT one pulsing,
         the rest quiet outlines. The task bar keeps the time story. */
      .bp-chips {
        display: flex; flex-wrap: wrap; align-items: center; gap: 6px;
        grid-column: 1 / -1; min-width: 0;
        padding: 3px 4px 5px calc(var(--d, 0) * 12px + 24px);
      }
      .bp-chips--card { padding: 0; }
      .bp-check {
        display: inline-flex; align-items: center; gap: 5px; min-width: 0;
        max-width: 30ch; padding: 3px 10px; border-radius: 999px;
        font-size: 11px; line-height: 1.5; color: var(--muted-text);
        border: 1px solid var(--border); background: transparent;
      }
      .bp-check-gi { flex: 0 0 auto; font-size: 10px; }
      .bp-check-t {
        min-width: 0; overflow: hidden; text-overflow: ellipsis;
        white-space: nowrap;
      }
      .bp-check.is-met {
        color: var(--ok); background: var(--ok-soft);
        border-color: color-mix(in srgb, var(--ok) 45%, var(--border));
      }
      .bp-check.is-next {
        color: var(--info); background: var(--info-soft);
        border-color: color-mix(in srgb, var(--info) 50%, var(--border));
        animation: bp-crit-pulse 2s ease-in-out infinite;
      }
      .bp-check--more { font-variant-numeric: tabular-nums; flex: 0 0 auto; }
      @keyframes bp-crit-pulse {
        0%   { opacity: 0.5; }
        50%  { opacity: 1; }
        100% { opacity: 0.5; }
      }
      /* while expanded, the card strip yields to the chart's chips */
      .bp-phone.is-expanded > .bp-chips--card { display: none; }
      /* ── inline peek (wave 24): the detail opens BELOW the pressed row ── */
      .bp-peek-host { grid-column: 1 / -1; min-width: 0; padding: 4px 0 6px; }
      .bp-peek-inline {
        border: 1px solid color-mix(in srgb, var(--info) 30%, var(--border));
        border-radius: 12px; background: var(--surface);
        box-shadow: 0 6px 22px rgb(0 0 0 / 0.10);
        animation: bp-notice-in 200ms ease-out 1;
      }
      .bp-peek-inline .bp-peek-head { padding: 12px 14px 10px; }
      .bp-peek-inline .bp-peek-title { font-size: 13.5px; margin: 6px 0 8px; }
      .bp-peek-inline .bp-peek-body {
        padding: 2px 14px 12px; max-height: 46vh; overflow-y: auto;
        scrollbar-width: thin; scrollbar-color: var(--border) transparent;
      }
      .bp-ledger .bp-peek-host { padding: 2px 0 4px; }
      /* Wave 19: the card READS, not just scans — the root's brief under the
         title, the ongoing task's text under its row, a paper chip when the
         detailed description lives as a PortableDoc design paper. */
      .bp-phone-desc {
        margin: 0; flex: 0 0 auto;
        font-size: 12px; line-height: 1.55; color: var(--muted-text);
        display: -webkit-box; -webkit-box-orient: vertical;
        -webkit-line-clamp: 5; overflow: hidden;
        white-space: pre-line; overflow-wrap: anywhere;
      }
      .bp-phone-nobrief {
        margin: 0; flex: 0 0 auto; font-size: 11px; font-style: italic;
        color: var(--muted-text); opacity: 0.75;
      }
      .bp-fam-row.has-desc { display: block; }
      .bp-fam-line { display: flex; align-items: center; gap: 6px; min-width: 0; }
      .bp-fam-desc {
        margin: 3px 0 2px; padding-left: 20px;
        font-size: 11.5px; line-height: 1.5; color: var(--muted-text);
        display: -webkit-box; -webkit-box-orient: vertical;
        -webkit-line-clamp: 3; overflow: hidden; overflow-wrap: anywhere;
      }
      /* Wave 20: the ongoing task's acceptance CHECKLIST inline — met rows
         dim, open rows bright; the exact "what's left" without a click. */
      .bp-crits {
        list-style: none; margin: 0; padding: 0; flex: 0 0 auto;
        display: flex; flex-direction: column; gap: 3px;
      }
      .bp-crits li {
        display: flex; align-items: flex-start; gap: 6px;
        font-size: 11.5px; line-height: 1.45; color: var(--text);
      }
      .bp-crits li > .gi { font-size: 10.5px; margin-top: 1px; }
      .bp-crits-t {
        min-width: 0; overflow: hidden; display: -webkit-box;
        -webkit-box-orient: vertical; -webkit-line-clamp: 2;
        overflow-wrap: anywhere;
      }
      .bp-crits li.is-met { color: var(--muted-text); }
      .bp-crits li.is-met .bp-crits-t { text-decoration: line-through; text-decoration-color: color-mix(in srgb, var(--muted-text) 45%, transparent); }
      .bp-crits--row { margin: 3px 0 2px; padding-left: 20px; }

      .bp-paper { color: var(--info); border-color: color-mix(in srgb, var(--info) 35%, var(--border)); }
      .bp-paper:hover { color: var(--info); }
      .bp-peek-paper {
        display: inline-block; margin-top: 8px; font-size: 12px;
        color: var(--info); text-decoration: none;
        padding: 4px 10px; border: 1px solid color-mix(in srgb, var(--info) 35%, var(--border));
        border-radius: 7px;
      }
      .bp-peek-paper:hover { background: var(--info-soft); }

      /* Honest window note — the done ledger shows the newest slice; the full
         count never silently disappears. */
      .bp-more {
        margin: 0; padding: 7px 8px; text-align: center;
        font-size: 11px; color: var(--muted-text);
        font-variant-numeric: tabular-nums;
      }

      /* ── task peek (wave 13): the right-hand inspector ────────────────────
         A card click slides a read-only detail panel over the LIVE board —
         no navigation away; the peeked id rides the URL. */
      .bp-scrim { position: fixed; inset: 0; z-index: 40; background: rgb(0 0 0 / 0.28); }
      .bp-peek {
        position: fixed; top: 0; right: 0; bottom: 0; z-index: 41;
        width: min(480px, 94vw); display: flex; flex-direction: column;
        background: var(--surface); border-left: 1px solid var(--border);
        box-shadow: -16px 0 44px rgb(0 0 0 / 0.22);
        animation: bp-peek-in 200ms cubic-bezier(0.22, 1, 0.36, 1) 1;
      }
      @keyframes bp-peek-in {
        0%   { opacity: 0; transform: translateX(14px); }
        100% { opacity: 1; transform: translateX(0); }
      }
      .bp-peek-head {
        flex: 0 0 auto; padding: 16px 18px 13px;
        border-bottom: 1px solid var(--border);
      }
      .bp-peek-status {
        display: flex; align-items: center; gap: 8px;
        font-size: 12px; color: var(--muted-text);
      }
      .bp-peek-state {
        text-transform: uppercase; letter-spacing: 0.07em;
        font-size: 10.5px; font-weight: 700;
      }
      .bp-peek-status .bp-age { margin-left: 0; padding-left: 0; }
      .bp-peek-x {
        margin-left: auto; border: 0; background: transparent;
        color: var(--muted-text); font-size: 1.3rem; line-height: 1;
        cursor: pointer; padding: 0 2px;
      }
      .bp-peek-x:hover { color: var(--text); }
      .bp-peek-title {
        margin: 8px 0 10px; font-size: 16px; font-weight: 600;
        letter-spacing: -0.01em; line-height: 1.35; color: var(--text);
      }
      .bp-peek-head .bp-meta { margin-top: 0; }
      .bp-peek-id {
        margin-left: auto; color: var(--muted-text); opacity: 0.7;
        font-variant-numeric: tabular-nums;
      }
      .bp-peek-body {
        flex: 1 1 auto; min-height: 0; overflow-y: auto;
        padding: 4px 18px 18px;
        scrollbar-width: thin; scrollbar-color: var(--border) transparent;
      }
      .bp-peek-sec { padding: 13px 0; border-bottom: 1px solid var(--border); }
      .bp-peek-sec > .bp-controls-label {
        display: flex; align-items: center; gap: 8px; margin: 0 0 9px;
      }
      .bp-peek-count {
        font-variant-numeric: tabular-nums; color: var(--ok);
        font-weight: 600; letter-spacing: 0; text-transform: none;
      }
      .bp-derived {
        color: var(--muted-text); font-weight: 500; letter-spacing: 0;
        text-transform: none;
      }
      .bp-purpose-grid { display: grid; gap: 0; margin: 0; }
      .bp-purpose-grid > div {
        display: grid; grid-template-columns: 72px minmax(0, 1fr); gap: 10px;
        padding: 6px 0; border-top: 1px solid color-mix(in srgb, var(--border) 62%, transparent);
      }
      .bp-purpose-grid > div:first-child { border-top: 0; padding-top: 0; }
      .bp-purpose-grid dt {
        color: var(--muted-text); font-size: 10px; font-weight: 700;
        letter-spacing: 0.07em; line-height: 1.5; text-transform: uppercase;
      }
      .bp-purpose-grid dd {
        min-width: 0; margin: 0; color: var(--text); font-size: 12.5px;
        line-height: 1.5; overflow-wrap: anywhere;
      }
      .bp-purpose-grid dd strong { color: var(--ok); font-variant-numeric: tabular-nums; }
      .bp-proof {
        margin-top: 9px; padding: 8px 10px; border-left: 2px solid var(--accent);
        border-radius: 0 6px 6px 0; background: var(--muted-surface);
      }
      .bp-proof h4 {
        margin: 0 0 5px; color: var(--muted-text); font-size: 10px;
        letter-spacing: 0.07em; text-transform: uppercase;
      }
      .bp-proof p { margin: 4px 0 0; color: var(--text); font-size: 11.5px; line-height: 1.45; }
      .bp-proof small { display: block; color: var(--muted-text); overflow-wrap: anywhere; }
      .bp-purpose-note { margin: 8px 0 0; color: var(--muted-text); font-size: 10.5px; line-height: 1.45; }
      .bp-peek-claim {
        margin: 0; font-size: 12.5px; color: var(--text);
        display: flex; gap: 6px; flex-wrap: wrap; align-items: baseline;
      }
      .bp-peek-claim .bp-worker { margin-left: 0; padding-left: 0; max-width: none; }
      .bp-peek-desc {
        margin: 0; font-size: 13px; line-height: 1.6; color: var(--text);
        white-space: pre-wrap; overflow-wrap: anywhere;
      }
      .bp-peek-crit {
        list-style: none; margin: 0; padding: 0;
        display: flex; flex-direction: column; gap: 9px;
      }
      .bp-peek-crit li { display: flex; gap: 8px; align-items: flex-start; }
      .bp-peek-crit li > .gi { margin-top: 2px; }
      .bp-peek-crit-b { flex: 1 1 auto; min-width: 0; }
      .bp-peek-crit-t { margin: 0; font-size: 12.5px; line-height: 1.5; color: var(--text); }
      .bp-peek-crit li.is-met .bp-peek-crit-t { color: var(--muted-text); }
      .bp-criteria-empty {
        margin: 0; color: var(--warn, var(--muted-text)); font-size: 12px; line-height: 1.45;
      }
      .bp-peek-evidence {
        margin: 4px 0 0; padding: 5px 9px;
        border-left: 2px solid var(--ok); border-radius: 0 6px 6px 0;
        background: var(--ok-soft); font-size: 11.5px; line-height: 1.5;
        color: var(--muted-text); overflow-wrap: anywhere;
      }
      .bp-peek-list {
        list-style: none; margin: 0; padding: 0;
        display: flex; flex-direction: column; gap: 3px;
      }
      .bp-peek-hop {
        display: flex; align-items: center; gap: 8px; width: 100%;
        text-align: left; font: inherit; font-size: 12.5px; color: var(--text);
        background: transparent; border: 1px solid transparent;
        border-radius: 7px; padding: 6px 8px; cursor: pointer;
        transition: background 120ms ease, border-color 120ms ease;
      }
      .bp-peek-hop:hover { background: var(--muted-surface); border-color: var(--border); }
      .bp-peek-hop:focus-visible { outline: 2px solid var(--ring); outline-offset: 1px; }
      .bp-peek-hop-t {
        flex: 1 1 auto; min-width: 0; overflow: hidden;
        text-overflow: ellipsis; white-space: nowrap;
      }
      .bp-peek-hop-s { flex: 0 0 auto; font-size: 11px; color: var(--muted-text); }
      .bp-peek-cli { margin: 14px 0 0; font-size: 11.5px; color: var(--muted-text); }
      .bp-peek-cli code {
        background: var(--muted-surface); border-radius: 5px;
        padding: 1px 6px; font-size: 11px;
      }
      /* Family tree (wave 15) — the task's whole neighbourhood in one map:
         spine (root → this task), siblings at every spine level, and the
         focused task's descendant subtree. Depth rides a --d custom prop. */
      .bp-tree {
        list-style: none; margin: 0; padding: 0;
        display: flex; flex-direction: column; gap: 2px;
      }
      .bp-tree-row {
        display: flex; align-items: center; gap: 6px; min-width: 0;
        padding-left: calc(var(--d) * 14px); font-size: 12.5px;
      }
      .bp-tree-row > .bp-peek-hop { padding: 4px 6px; }
      .bp-tree-twig { color: var(--border); flex: 0 0 auto; font-size: 10px; }
      .bp-tree-row.is-self {
        background: var(--info-soft);
        border: 1px solid color-mix(in srgb, var(--info) 30%, transparent);
        border-radius: 7px; padding-top: 5px; padding-bottom: 5px;
        padding-right: 8px;
      }
      .bp-tree-row.is-self .bp-tree-t { font-weight: 600; }
      .bp-tree-t {
        flex: 1 1 auto; min-width: 0; color: var(--text);
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .bp-tree-self-tag {
        flex: 0 0 auto; font-size: 9.5px; font-weight: 700;
        letter-spacing: 0.07em; text-transform: uppercase; color: var(--info);
      }
      .bp-tree-row.is-gone { color: var(--muted-text); opacity: 0.7; }
      .bp-tree-row.is-gone .bp-tree-t { color: var(--muted-text); }
      .bp-tree-more {
        padding-left: calc(var(--d) * 14px + 22px);
        font-size: 11px; color: var(--muted-text);
        font-variant-numeric: tabular-nums;
      }
      .bp-peek-subtree {
        font-variant-numeric: tabular-nums; color: var(--muted-text);
        font-weight: 500; letter-spacing: 0; text-transform: none;
      }
      /* Activity log (wave 14) — the task's durable history, newest first. */
      .bp-peek-log {
        list-style: none; margin: 0; padding: 0;
        display: flex; flex-direction: column; gap: 6px;
      }
      .bp-peek-log li {
        display: flex; align-items: baseline; gap: 8px; font-size: 12px;
      }
      .bp-peek-log li::before {
        content: ""; width: 5px; height: 5px; border-radius: 999px;
        background: var(--border); align-self: center; flex: 0 0 auto;
      }
      .bp-log-k { color: var(--text); font-weight: 500; }
      .bp-log-w {
        color: var(--muted-text); max-width: 20ch;
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .bp-peek-log .bp-age { margin-left: auto; padding-left: 8px; }

      /* ── §1 white-ladder glyph vocabulary ────────────────────────────── */
      /* Lifecycle hues are the GOVERNED --life-* role tokens (design/
         status-manifest.json → tokens.json → the root layout's GENERATED
         block), which flip on html[data-theme="dark"] — never a hand-copied
         hex per theme (au-r3). */
      .gi {
        display: inline-block; width: 1.1em; text-align: center;
        font-family: var(--font-mono, monospace); line-height: 1.3;
      }
      .gi--open { color: currentColor; opacity: 0.5; }      /* backlog: dim ○ */
      .gi--ready { color: currentColor; opacity: 1; }       /* unchecked: bright ○ */
      .gi--blocked { color: var(--life-blocked); font-weight: 700; }  /* amber ! */
      .gi--done { color: var(--life-done); }                          /* teal ✓ */
      .gi--cancelled { color: var(--life-cancelled); }
      /* Thought states (TLV D11/D14) — dim by design: visible, never claimable.
         The hues are the GENERATED --life-considering / --life-researching
         tokens tlv-s2 emitted, same governance as every role above. */
      .gi--considering { color: var(--life-considering); opacity: 0.75; }
      .gi--researching { color: var(--life-researching); opacity: 0.85; }
      /* The fail-open role: a lifecycle value this build does not know paints
         the neutral foreground, dim — it must never borrow a work state's hue. */
      .gi--unknown { color: var(--fg-dim); opacity: 0.6; }

      /* in_progress: pure-CSS Braille spinner, TUI-identical 10 frames,
         ~80ms/frame (800ms cycle). The glyph is supplied entirely by ::before
         so the frame-cycle needs no JS and survives a static render. */
      .gi--in_progress { color: var(--life-in_progress); }
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
      /* Sync health rides the same governed lifecycle roles: synced = the
         done teal, detached = the blocked amber (theme-aware, au-r3). */
      .bp-gh-dot.is-synced { background: var(--life-done); }
      .bp-gh-dot.is-detached { background: var(--life-blocked); }
      .bp-gh-state { opacity: 0.65; }

      /* Dark-surface elevation shadows — keyed off the Studio theme attribute,
         with the media query as the pre-hydration fallback. The §1 lifecycle
         hues need no fork here anymore: the --life-* role tokens flip with the
         theme at the root layout. */
      @media (prefers-color-scheme: dark) {
        .bp-card:hover { box-shadow: 0 2px 10px rgb(0 0 0 / 0.35); }
        .bp-seg-opt.is-active { box-shadow: 0 1px 2px rgb(0 0 0 / 0.4); }
      }
      html[data-theme="dark"] .bp-card:hover { box-shadow: 0 2px 10px rgb(0 0 0 / 0.35); }
      html[data-theme="dark"] .bp-phone:hover { box-shadow: 0 10px 30px rgb(0 0 0 / 0.45); }

      /* Motion is a signal, not decoration — honor the reader's preference. */
      @media (prefers-reduced-motion: reduce) {
        .gi--in_progress::before { animation: none; content: "⠿"; }
        .bp-bar-fill { transition: none; }
        .bp-flash { animation: none; }
        .m-bump { animation: none; }
        .bp-notice { animation: none; }
        .bp-peek { animation: none; }
        .bp-check.is-next { animation: none; opacity: 1; }
        .bp-chip { transition: none; }
      }
    </style>

    <main class="bp-page">
      <div class="bp-head">
        <div class="bp-head-l">
          <h1 class="bp-h1">Projects</h1>
          <p class="bp-sub">
            Every family of work, live — click a card for the full story.
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
            <%= for lane <- @view.lanes do %>
              <%= if lane_settled?(lane) do %>
                <details
                  class="bp-lane bp-lane--settled"
                  data-role="lane-settled"
                  data-lane={lane_dom_id(lane.key)}
                >
                  <summary>
                    <span class="gi gi--done" aria-hidden="true">✓</span>
                    <span class="bp-settled-label" data-role="lane-label"><%= lane.label %></span>
                    <span class="bp-settled-tally" data-role="settled-tally">
                      all <%= lane.counts[:done] %> done
                    </span>
                    <span :if={newest_done_at(lane)} class="bp-age">
                      last <%= age_label(newest_done_at(lane)) %>
                    </span>
                  </summary>
                  <.done_ledger cards={lane.columns[:done]} last_change={@last_change} peek={nil} />
                </details>
              <% else %>
                <section class="bp-lane" data-role="lane" data-lane={lane_dom_id(lane.key)}>
                  <h2 class="bp-lane-h" data-role="lane-label"><%= lane.label %></h2>
                  <.board_grid
                    lane={lane}
                    last_change={@last_change}
                    done_overflow={0}
                    family={false}
                    id={"bp-board-lane-" <> lane_dom_id(lane.key)}
                  />
                </section>
              <% end %>
            <% end %>
          </div>
        <% else %>
          <%= if lane_settled?(hd(@view.lanes)) do %>
            <div class="bp-settled" data-role="board-settled">
              <div class="bp-settled-hero">
                <span class="gi gi--done bp-settled-glyph" aria-hidden="true">✓</span>
                <h2 class="bp-settled-h">Pipeline clear</h2>
                <p class="bp-settled-sub">
                  <%= settled_total(@view, @board) %> tasks done — nothing open, ready,
                  in flight, or blocked. File the next one with <code>bp task create</code>.
                </p>
              </div>
              <.done_ledger
                cards={hd(@view.lanes).columns[:done]}
                last_change={@last_change}
                peek={@peek}
              />
              <p :if={done_overflow(@view, @board) > 0} class="bp-more" data-role="done-overflow">
                + <%= done_overflow(@view, @board) %> earlier — newest shown
              </p>
            </div>
          <% else %>
            <%= if @view[:family?] == true do %>
              <.deck
                lane={hd(@view.lanes)}
                last_change={@last_change}
                done_overflow={done_overflow(@view, @board)}
                expanded={@expanded}
                peek={@peek}
              />
            <% else %>
              <.board_grid
                lane={hd(@view.lanes)}
                last_change={@last_change}
                done_overflow={done_overflow(@view, @board)}
                family={false}
                id="bp-projects-board"
              />
            <% end %>
          <% end %>
        <% end %>
      <% end %>

      <%= if @peek && !peek_hosted?(@view, @expanded, @peek) do %>
        <div class="bp-scrim" data-role="peek-scrim" phx-click="peek-close" aria-hidden="true"></div>
        <.peek_panel peek={@peek} />
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
    <div
      id={@id}
      class="bp-board"
      data-role="board"
      data-family={@family && "true"}
      phx-hook="BarkparkBoardDrag"
    >
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
          phx-click="peek"
          phx-value-task={card.doc_id}
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
            <span :if={card.updated_at} class="bp-age" data-role="age">
              <%= age_label(card.updated_at) %>
            </span>
          </div>

          <p
            :if={col == :in_progress && !card[:family] && focus_of(card)}
            class="bp-focus"
            data-role="focus"
          >
            <span class="bp-focus-k">now</span>
            <span class="bp-focus-t"><%= focus_of(card).title %></span>
            <span :if={focus_of(card).worker} class="bp-focus-w">
              @<%= focus_of(card).worker %>
            </span>
          </p>

          <ul :if={col != :done && card[:family]} class="bp-fam" data-role="family">
            <li
              :for={row <- card.family.rows}
              class="bp-fam-row"
              style={"--d: #{row.depth};"}
              data-role="family-row"
              data-doc-id={row.doc_id}
            >
              <span :if={row.depth > 1} class="bp-tree-twig" aria-hidden="true">└</span>
              <span class={"gi gi--#{row.color_role}"} aria-hidden="true"><%= glyph_text(row) %></span>
              <span class="bp-fam-t"><%= row.title || row.doc_id %></span>
              <span :if={row.worker} class="bp-focus-w">@<%= row.worker %></span>
            </li>
            <li :if={card.family.more > 0} class="bp-fam-more" data-role="family-more">
              + <%= card.family.more %> more inside
            </li>
          </ul>

          <div :if={col != :done} class="bp-meta">
            <span :if={card.priority} class="bp-pip" data-role="priority" data-priority={card.priority}>
              P<%= card.priority %>
            </span>
            <span :if={card.parent_id} class="bp-goal" data-role="goal"><%= card.parent_id %></span>
            <span
              :if={family_tally(card)}
              class={[
                "bp-sub",
                family_tally(card).done == family_tally(card).total && "bp-sub--all-done"
              ]}
              data-role="subtasks"
              title="subtasks done / total"
            >
              <%= family_tally(card).done %>/<%= family_tally(card).total %> sub
            </span>
            <span :for={label <- Enum.take(card.labels, 2)} class="bp-label" data-role="label">
              <%= label %>
            </span>
            <span :if={length(card.labels) > 2} class="bp-label bp-label--more" data-role="label-more">
              +<%= length(card.labels) - 2 %>
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

            <span :if={card.worker} class="bp-worker" data-role="worker" title={card.worker}>
              <%= card.worker %>
            </span>
          </div>

          <div :if={col != :done and card.criteria} class="bp-progress" data-role="progress">
            <span class="bp-progress-track"><span
              class="bp-progress-fill"
              style={"width: #{crit_pct(card.criteria)}%;"}
            ></span></span>
            <span
              class={["bp-crit", card.criteria.met == 0 && "bp-crit--zero"]}
              data-role="criteria"
            >
              <%= card.criteria.met %>/<%= card.criteria.total %>
            </span>
          </div>

          <p :if={col == :blocked and open_blockers(card) > 0} class="bp-block-note" data-role="blockers">
            waiting on <%= open_blockers(card) %> of <%= length(card.blocker_statuses) %> blockers
          </p>
        </article>

          <p :if={col == :done and @done_overflow > 0} class="bp-more" data-role="done-overflow">
            + <%= @done_overflow %> earlier — newest shown
          </p>
        </div>
      </section>
    </div>
    """
  end

  # The compact done ledger — the SAME one-line row the Done column renders
  # (glyph + title + age), reused by settled lanes and the settled board where
  # there is no column chrome to live in. Not draggable: a done card refuses
  # every move anyway, and there are no drop targets here.
  defp done_ledger(assigns) do
    ~H"""
    <div class="bp-ledger" data-role="done-ledger">
      <%= for card <- @cards do %>
      <article
        class={["bp-card", "bp-card--done", just_moved?(@last_change, card) && "bp-flash"]}
        data-role="task-card"
        data-col="done"
        data-doc-id={card.doc_id}
        data-just-moved={just_moved?(@last_change, card) && "true"}
        phx-click="peek"
        phx-value-task={card.doc_id}
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
          <span :if={card.updated_at} class="bp-age" data-role="age">
            <%= age_label(card.updated_at) %>
          </span>
        </div>
      </article>

      <div
        :if={@peek && @peek.doc_id == card.doc_id}
        class="bp-peek-host"
        data-role="peek-host"
      >
        <.peek_inline peek={@peek} />
      </div>
      <% end %>
    </div>
    """
  end

  # The task peek panel (wave 13) — a read-only right-hand inspector over the
  # live board: status header, claim lease, description, criteria WITH their
  # close-time evidence, children (in-flight first, hop to re-peek), titled
  # blockers, and the CLI escape hatch. Esc / × / scrim-click close.
  # The task detail CARD — header + sections — shared by the inline expansion
  # (wave 24: the information opens BELOW the row you pressed) and the aside
  # FALLBACK (a shared ?task= URL whose task has no visible row on this view).
  defp peek_card(assigns) do
    ~H"""
      <header class="bp-peek-head">
        <div class="bp-peek-status">
          <span class={"gi gi--#{peek_role(@peek)}"} aria-hidden="true">
            <%= role_glyph(peek_role(@peek)) %>
          </span>
          <span class="bp-peek-state" data-role="peek-state"><%= peek_state_label(@peek) %></span>
          <span :if={@peek.priority} class="bp-pip" data-priority={@peek.priority}>
            P<%= @peek.priority %>
          </span>
          <span :if={@peek.updated_at} class="bp-age"><%= age_label(@peek.updated_at) %></span>
          <button
            type="button"
            class="bp-peek-x"
            phx-click="peek-close"
            data-role="peek-close"
            aria-label="Close task details"
          >×</button>
        </div>
        <h2 class="bp-peek-title" data-role="peek-title"><%= @peek.title || @peek.doc_id %></h2>
        <div class="bp-meta">
          <span :if={@peek.parent_id && @peek.ancestors == []} class="bp-goal" data-role="peek-goal"><%= @peek.parent_id %></span>
          <span :for={label <- @peek.labels} class="bp-label"><%= label %></span>
          <a
            :if={github_badge?(@peek.github)}
            class="bp-gh"
            href={gh_href(@peek.github)}
            target="_blank"
            rel="noopener"
          >
            #<%= @peek.github["issue"] %>
            <span class="bp-gh-state"><%= @peek.github["state"] %></span>
          </a>
          <span class="bp-peek-id"><%= @peek.doc_id %></span>
        </div>
      </header>

      <div class="bp-peek-body">
        <section :if={@peek.criteria} class="bp-peek-sec" data-role="peek-criteria">
          <h3 class="bp-controls-label">
            Criteria
            <span class="bp-peek-count">
              <%= Enum.count(@peek.criteria, & &1.met) %>/<%= length(@peek.criteria) %>
            </span>
          </h3>
          <ul class="bp-peek-crit">
            <li :for={c <- @peek.criteria} class={c.met && "is-met"} data-role="peek-criterion">
              <span class={"gi " <> if(c.met, do: "gi--done", else: "gi--ready")} aria-hidden="true">
                <%= if c.met, do: "✓", else: "○" %>
              </span>
              <div class="bp-peek-crit-b">
                <p class="bp-peek-crit-t"><%= c.text %></p>
                <p :if={c.evidence} class="bp-peek-evidence" data-role="peek-evidence">
                  <%= c.evidence %>
                </p>
              </div>
            </li>
          </ul>
          <p :if={@peek.criteria == []} class="bp-criteria-empty">
            No acceptance criteria recorded — completion cannot be verified.
          </p>
        </section>

        <section class="bp-peek-sec bp-purpose" data-role="peek-purpose">
          <h3 class="bp-controls-label">
            Purpose
            <span :if={!@peek.purpose.authored} class="bp-derived">derived</span>
          </h3>
          <dl class="bp-purpose-grid">
            <div><dt>Part of</dt><dd><%= @peek.purpose.part_of %></dd></div>
            <div><dt>Impact</dt><dd><%= @peek.purpose.impact %></dd></div>
            <div><dt>Does</dt><dd><%= @peek.purpose.statement %></dd></div>
            <div><dt>Why</dt><dd><%= @peek.purpose.why %></dd></div>
            <div><dt>Endgame</dt><dd><%= @peek.purpose.endgame %></dd></div>
            <div>
              <dt>Important</dt>
              <dd><strong><%= @peek.purpose.importance.score %>/100</strong> · <%= @peek.purpose.importance.reason %></dd>
            </div>
            <div>
              <dt>Relevant</dt>
              <dd><strong><%= @peek.purpose.relevance.score %>/100</strong> · <%= @peek.purpose.relevance.reason %></dd>
            </div>
          </dl>
          <div :if={@peek.purpose.proof != []} class="bp-proof" data-role="peek-purpose-proof">
            <h4>Proof</h4>
            <p :for={proof <- @peek.purpose.proof}>
              <strong><%= proof.claim %>:</strong> <%= proof.evidence %>
              <small :if={proof.source}><%= proof.source %></small>
            </p>
          </div>
          <p :if={!@peek.purpose.authored} class="bp-purpose-note">
            Derived from live task facts; author a purpose dossier to replace these defaults.
          </p>
        </section>

        <section :if={@peek.claim} class="bp-peek-sec" data-role="peek-claim">
          <h3 class="bp-controls-label">Claim</h3>
          <p class="bp-peek-claim">
            <span class="bp-worker"><%= @peek.claim.worker %></span>
            <span :if={@peek.claim.epoch}>· epoch <%= @peek.claim.epoch %></span>
            <span :if={@peek.claim.at}>· held <%= age_label(@peek.claim.at) %></span>
          </p>
        </section>

        <section :if={@peek.tree != []} class="bp-peek-sec" data-role="peek-tree">
          <h3 class="bp-controls-label">
            Tree
            <span :if={@peek.subtree} class="bp-peek-subtree" data-role="peek-subtree">
              subtree <%= @peek.subtree.done %>/<%= @peek.subtree.total %>
            </span>
          </h3>
          <ul class="bp-tree">
            <%= for n <- @peek.tree do %>
              <li
                :if={n.kind == :more}
                class="bp-tree-more"
                style={"--d: #{n.depth};"}
                data-role="tree-more"
              >
                + <%= n.count %> more
              </li>
              <li
                :if={n.kind == :node}
                class={["bp-tree-row", n.self && "is-self", n.missing && "is-gone"]}
                style={"--d: #{n.depth};"}
                data-role="tree-node"
                data-doc-id={n.doc_id}
              >
                <span :if={n.depth > 0} class="bp-tree-twig" aria-hidden="true">└</span>
                <%= if n.self or n.missing do %>
                  <span class={"gi gi--#{n.role}"} aria-hidden="true"><%= n.glyph %></span>
                  <span class="bp-tree-t"><%= n.title || n.doc_id %></span>
                  <span :if={n.sub} class="bp-peek-hop-s"><%= n.sub.done %>/<%= n.sub.total %></span>
                  <span :if={n.self} class="bp-tree-self-tag">this task</span>
                <% else %>
                  <button
                    type="button"
                    class="bp-peek-hop bp-tree-hop"
                    phx-click="peek"
                    phx-value-task={n.doc_id}
                    data-role="tree-hop"
                  >
                    <span class={"gi gi--#{n.role}"} aria-hidden="true"><%= n.glyph %></span>
                    <span class="bp-peek-hop-t"><%= n.title || n.doc_id %></span>
                    <span :if={n.sub} class="bp-peek-hop-s"><%= n.sub.done %>/<%= n.sub.total %></span>
                    <span :if={n.worker} class="bp-focus-w">@<%= n.worker %></span>
                  </button>
                <% end %>
              </li>
            <% end %>
          </ul>
        </section>

        <section
          :if={@peek.description || @peek.design_doc}
          class="bp-peek-sec"
          data-role="peek-description"
        >
          <h3 class="bp-controls-label">Description</h3>
          <p :if={@peek.description} class="bp-peek-desc"><%= @peek.description %></p>
          <a
            :if={@peek.design_doc}
            class="bp-peek-paper"
            data-role="peek-design-doc"
            href={"/papers/" <> @peek.design_doc}
            target="_blank"
            rel="noopener"
          >
            ❡ Read the full design paper →
          </a>
        </section>

        <section :if={@peek.blockers != []} class="bp-peek-sec" data-role="peek-blockers">
          <h3 class="bp-controls-label">Blocked by</h3>
          <ul class="bp-peek-list">
            <li :for={b <- @peek.blockers}>
              <button
                type="button"
                class="bp-peek-hop"
                phx-click="peek"
                phx-value-task={b.doc_id}
                data-role="peek-blocker"
              >
                <span class={"gi gi--#{safe_role(b.lifecycle_status)}"} aria-hidden="true">
                  <%= role_glyph(safe_role(b.lifecycle_status)) %>
                </span>
                <span class="bp-peek-hop-t"><%= b.title || b.doc_id %></span>
                <span class="bp-peek-hop-s"><%= b.lifecycle_status %></span>
              </button>
            </li>
          </ul>
        </section>

        <section :if={@peek.blocks != []} class="bp-peek-sec" data-role="peek-blocks">
          <h3 class="bp-controls-label">Blocks <span class="bp-peek-count"><%= length(@peek.blocks) %></span></h3>
          <ul class="bp-peek-list">
            <li :for={b <- @peek.blocks}>
              <button
                type="button"
                class="bp-peek-hop"
                phx-click="peek"
                phx-value-task={b.doc_id}
                data-role="peek-blocks-row"
              >
                <span class={"gi gi--#{safe_role(b.lifecycle_status)}"} aria-hidden="true">
                  <%= role_glyph(safe_role(b.lifecycle_status)) %>
                </span>
                <span class="bp-peek-hop-t"><%= b.title || b.doc_id %></span>
                <span class="bp-peek-hop-s"><%= b.lifecycle_status %></span>
              </button>
            </li>
          </ul>
        </section>

        <section :if={@peek.events != [] or @peek.created_at} class="bp-peek-sec" data-role="peek-activity">
          <h3 class="bp-controls-label">Activity</h3>
          <ol class="bp-peek-log">
            <li :for={e <- @peek.events} data-role="peek-event">
              <span class="bp-log-k"><%= e.kind %></span>
              <span :if={e.worker} class="bp-log-w">@<%= e.worker %></span>
              <span :if={e.at} class="bp-age"><%= age_label(e.at) %></span>
            </li>
            <li :if={@peek.created_at} data-role="peek-created">
              <span class="bp-log-k">created</span>
              <span class="bp-age"><%= age_label(@peek.created_at) %></span>
            </li>
          </ol>
        </section>

        <p class="bp-peek-cli">
          Inspect in the terminal: <code>bp task show <%= @peek.doc_id %></code>
        </p>
      </div>
    """
  end

  # Fallback shell only (wave 24): a right-hand panel for a peeked task with
  # NO visible host row — a shared URL into a filtered/collapsed view. When
  # the row is visible, the SAME card renders inline beneath it instead.
  defp peek_panel(assigns) do
    ~H"""
    <aside
      class="bp-peek"
      data-role="peek"
      aria-label="Task details"
      phx-window-keydown="peek-close"
      phx-key="escape"
    >
      <.peek_card peek={@peek} />
    </aside>
    """
  end

  # The inline expansion (wave 24) — the same detail card, homed under the
  # pressed row. Esc still closes.
  defp peek_inline(assigns) do
    ~H"""
    <div
      class="bp-peek-inline"
      data-role="peek"
      phx-window-keydown="peek-close"
      phx-key="escape"
    >
      <.peek_card peek={@peek} />
    </div>
    """
  end

  # ── the Deck (wave 18): the default view ────────────────────────────────────
  #
  # The status kanban never fit the family principle: once a card carries its
  # whole family, five columns force ONE dimension (status) to own the layout
  # while wasting most of the canvas on near-empty buckets. The deck makes
  # status a CHIP: one horizontal snap-rail of identical phone-frame (9:19.5)
  # context cards, ordered by relevance — in-flight families first, then
  # ready, blocked, open — and Done is the LAST card, a single ledger phone.
  # Cards are not draggable here (there are no drop targets); a click peeks.
  # Grouped/filtered views keep the kanban + drag — the drill-down.
  # THOUGHT COLUMNS ARE DELIBERATELY ABSENT (TLV charter ruling): the deck is the
  # WORK FUNNEL — what can be picked up, in relevance order. Considering and
  # researching are visible as their own columns in the desktop grid
  # (`board_grid/1`, which walks the full `Board.columns/0`); putting them on the
  # rail would put un-actionable cards in front of actionable ones. They are not
  # dropped from the model either — `lane_settled?/1` counts them as live, so a
  # board holding only thought cards never collapses to the done ledger.
  @deck_order [:in_progress, :ready, :blocked, :open]

  defp deck(assigns) do
    ~H"""
    <div class="bp-deck" data-role="deck">
      <article
        :for={card <- deck_cards(@lane)}
        class={[
          "bp-phone",
          "bp-phone--#{card.col}",
          expanded?(@expanded, card) && "is-expanded",
          just_moved?(@last_change, card) && "bp-flash"
        ]}
        data-role="task-card"
        data-col={card.col}
        data-doc-id={card.doc_id}
        data-just-moved={just_moved?(@last_change, card) && "true"}
        phx-click={!expanded?(@expanded, card) && "expand"}
        phx-value-task={card.doc_id}
      >
        <header class="bp-phone-head">
          <span
            class={"gi gi--#{card.color_role}"}
            data-role="glyph"
            data-status={card.lifecycle_status}
            aria-hidden="true"
          ><%= glyph_text(card) %></span>
          <span
            class={["bp-phone-state", card.col == :in_progress && "is-flight"]}
            data-role="deck-state"
          >
            <%= deck_state(card.col) %>
          </span>
          <span :if={card.priority} class="bp-pip" data-role="priority" data-priority={card.priority}>
            P<%= card.priority %>
          </span>
          <span :if={card.updated_at} class="bp-age" data-role="age">
            <%= age_label(card.updated_at) %>
          </span>
          <button
            :if={expanded?(@expanded, card)}
            type="button"
            class="bp-x-details"
            phx-click="peek"
            phx-value-task={card.doc_id}
            data-role="expand-details"
          >
            details
          </button>
          <button
            :if={expanded?(@expanded, card)}
            type="button"
            class="bp-peek-x"
            phx-click="expand-close"
            data-role="expand-close"
            aria-label="Collapse the timeline"
          >
            ×
          </button>
        </header>

        <h3 class="bp-phone-title" data-role="card-title"><%= card.title %></h3>

        <p :if={card[:description_excerpt]} class="bp-phone-desc" data-role="card-desc">
          <%= card.description_excerpt %>
        </p>

        <p
          :if={card[:family] && !card[:description_excerpt] && !card[:design_doc]}
          class="bp-phone-nobrief"
          data-role="brief-missing"
        >
          no brief — add a description or link a design paper
        </p>

        <div
          :if={card.lifecycle_status == "in_progress" && card[:criteria_list]}
          class="bp-chips bp-chips--card"
          data-role="card-criteria"
        >
          <span
            :for={c <- card.criteria_list}
            class={["bp-check", c.met && "is-met"]}
            data-role="card-criterion"
            title={c.text}
          >
            <span class="bp-check-gi" aria-hidden="true"><%= if c.met, do: "✓", else: "○" %></span>
            <span class="bp-check-t"><%= c.text %></span>
          </span>
        </div>

        <p
          :if={card.col == :in_progress && !card[:family] && focus_of(card)}
          class="bp-focus"
          data-role="focus"
        >
          <span class="bp-focus-k">now</span>
          <span class="bp-focus-t"><%= focus_of(card).title %></span>
          <span :if={focus_of(card).worker} class="bp-focus-w">
            @<%= focus_of(card).worker %>
          </span>
        </p>

        <div class="bp-phone-body">
          <ul :if={card[:family]} class="bp-fam" data-role="family">
            <li
              :for={row <- card.family.rows}
              class={["bp-fam-row", row[:desc] && "has-desc"]}
              style={"--d: #{row.depth};"}
              data-role="family-row"
              data-doc-id={row.doc_id}
            >
              <div class="bp-fam-line">
                <span :if={row.depth > 1} class="bp-tree-twig" aria-hidden="true">└</span>
                <span class={"gi gi--#{row.color_role}"} aria-hidden="true"><%= glyph_text(row) %></span>
                <span class="bp-fam-t"><%= row.title || row.doc_id %></span>
                <span :if={row.worker} class="bp-focus-w">@<%= row.worker %></span>
              </div>
              <p :if={row[:desc]} class="bp-fam-desc" data-role="family-desc"><%= row.desc %></p>
              <ul :if={row[:crits]} class="bp-crits bp-crits--row" data-role="family-criteria">
                <li :for={c <- row.crits} class={c.met && "is-met"} data-role="family-criterion">
                  <span
                    class={"gi " <> if(c.met, do: "gi--done", else: "gi--ready")}
                    aria-hidden="true"
                  >
                    <%= if c.met, do: "✓", else: "○" %>
                  </span>
                  <span class="bp-crits-t"><%= c.text %></span>
                </li>
              </ul>
            </li>
            <li :if={card.family.more > 0} class="bp-fam-more" data-role="family-more">
              + <%= card.family.more %> more inside
            </li>
          </ul>

          <p :if={card.col == :blocked and open_blockers(card) > 0} class="bp-block-note" data-role="blockers">
            waiting on <%= open_blockers(card) %> of <%= length(card.blocker_statuses) %> blockers
          </p>

          <%= if expanded?(@expanded, card) do %>
            <% g = gantt_data(card) %>
            <div class="bp-gantt" data-role="gantt">
              <div class="bp-gantt-axis">
                <span><%= if g.origin, do: age_label(g.origin) <> " ago", else: "" %></span>
                <span>now</span>
              </div>
              <div
                :for={row <- g.rows}
                class="bp-gantt-row"
                style={"--d: #{row.depth};"}
                data-role="gantt-row"
                data-doc-id={row.doc_id}
              >
                <button
                  type="button"
                  class="bp-gantt-label"
                  phx-click="peek"
                  phx-value-task={row.doc_id}
                  data-role="gantt-label"
                >
                  <span :if={row.depth > 1} class="bp-tree-twig" aria-hidden="true">└</span>
                  <span class={"gi gi--#{row.color_role}"} aria-hidden="true">
                    <%= glyph_text(row) %>
                  </span>
                  <span class="bp-gantt-t"><%= row.title || row.doc_id %></span>
                  <span :if={row.worker} class="bp-focus-w">@<%= row.worker %></span>
                </button>
                <div class="bp-gantt-track">
                  <span
                    class={"bp-gantt-bar is-#{row.color_role}"}
                    data-role="gantt-bar"
                    style={"left: #{row.left}%; width: #{row.width}%;"}
                  >
                  </span>
                </div>

                <div :if={row[:desc]} class="bp-gantt-detail" data-role="gantt-detail">
                  <p class="bp-fam-desc" data-role="family-desc"><%= row.desc %></p>
                </div>

                <div
                  :if={row[:crits]}
                  class="bp-chips"
                  style={"--d: #{row.depth};"}
                  data-role="gantt-criteria"
                >
                  <%= for {c, i} <- Enum.with_index(Enum.take(row.crits, 8)) do %>
                    <span
                      class={[
                        "bp-check",
                        c.met && "is-met",
                        !c.met && i == next_unmet_index(row.crits) && "is-next"
                      ]}
                      data-role="gantt-criterion"
                      title={c.text}
                    >
                      <span class="bp-check-gi" aria-hidden="true">
                        <%= if c.met, do: "✓", else: "○" %>
                      </span>
                      <span class="bp-check-t"><%= c.text %></span>
                    </span>
                  <% end %>
                  <span
                    :if={length(row.crits) > 8}
                    class="bp-check bp-check--more"
                    data-role="gantt-crit-more"
                  >
                    +<%= length(row.crits) - 8 %>
                  </span>
                </div>

                <div
                  :if={@peek && @peek.doc_id == row.doc_id}
                  class="bp-peek-host"
                  data-role="peek-host"
                >
                  <.peek_inline peek={@peek} />
                </div>
              </div>
              <p :if={card[:family] && card.family.more > 0} class="bp-fam-more">
                + <%= card.family.more %> more inside
              </p>
            </div>
          <% end %>
        </div>

        <div :if={card.criteria} class="bp-progress" data-role="progress">
          <span class="bp-progress-track"><span
            class="bp-progress-fill"
            style={"width: #{crit_pct(card.criteria)}%;"}
          ></span></span>
          <span
            class={["bp-crit", card.criteria.met == 0 && "bp-crit--zero"]}
            data-role="criteria"
          >
            <%= card.criteria.met %>/<%= card.criteria.total %>
          </span>
        </div>

        <div class="bp-meta">
          <span :if={card.parent_id} class="bp-goal" data-role="goal"><%= card.parent_id %></span>
          <span
            :if={family_tally(card)}
            class={[
              "bp-sub",
              family_tally(card).done == family_tally(card).total && "bp-sub--all-done"
            ]}
            data-role="subtasks"
            title="subtasks done / total"
          >
            <%= family_tally(card).done %>/<%= family_tally(card).total %> sub
          </span>
          <span :for={label <- Enum.take(card.labels, 2)} class="bp-label" data-role="label">
            <%= label %>
          </span>
          <span :if={length(card.labels) > 2} class="bp-label bp-label--more" data-role="label-more">
            +<%= length(card.labels) - 2 %>
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

          <a
            :if={card[:design_doc]}
            class="bp-gh bp-paper"
            data-role="design-doc"
            href={"/papers/" <> card.design_doc}
            target="_blank"
            rel="noopener"
          >
            ❡ design paper
          </a>

          <span :if={card.worker} class="bp-worker" data-role="worker" title={card.worker}>
            <%= card.worker %>
          </span>
        </div>
      </article>

      <article
        :if={(@lane.counts[:done] || 0) > 0}
        class="bp-phone bp-phone--ledger"
        data-role="deck-done"
      >
        <header class="bp-phone-head">
          <span class="gi gi--done" aria-hidden="true">✓</span>
          <span class="bp-phone-state">done</span>
          <span class="bp-age" data-role="col-count"><%= @lane.counts[:done] %></span>
        </header>
        <h3 class="bp-phone-title">Shipped</h3>
        <div class="bp-phone-body">
          <.done_ledger cards={@lane.columns[:done]} last_change={@last_change} peek={@peek} />
          <p :if={@done_overflow > 0} class="bp-more" data-role="done-overflow">
            + <%= @done_overflow %> earlier — newest shown
          </p>
        </div>
      </article>
    </div>
    """
  end

  # The rail order: relevance, not buckets — the active continuum first
  # (in-flight, then ready), then stuck, then backlog. Done rides the ledger
  # card at the end.
  defp deck_cards(lane) do
    Enum.flat_map(@deck_order, fn col -> lane.columns[col] || [] end)
  end

  defp deck_state(:in_progress), do: "in flight"
  defp deck_state(col), do: col |> Atom.to_string() |> String.replace("_", " ")

  # Which cards are expanded (wave 23): with NO ?expand= param the flight
  # deck greets you OPEN — every in-flight card renders its gantt by default.
  # An explicit ?expand=<id> narrows to that one card; the "none" sentinel
  # (what × patches to) collapses everything. The bare URL stays the default
  # experience.
  # Does the peeked task have a VISIBLE host row on this view (wave 24)?
  # Hosted = rendered inline beneath that row; unhosted (a shared URL into a
  # filtered/collapsed/grouped view) falls back to the side panel. Hosts are
  # deck-only: an EXPANDED card's root/family gantt rows, or a done-ledger row.
  defp peek_hosted?(view, expanded, peek) do
    view[:family?] == true and is_map(peek) and
      Enum.any?(view.lanes, fn lane ->
        done_hit = Enum.any?(lane.columns[:done] || [], &(&1.doc_id == peek.doc_id))

        live_hit =
          Enum.any?([:in_progress, :ready, :blocked, :open], fn col ->
            Enum.any?(lane.columns[col] || [], fn c ->
              expanded?(expanded, c) and
                (c.doc_id == peek.doc_id or
                   Enum.any?((c[:family] && c.family.rows) || [], &(&1.doc_id == peek.doc_id)))
            end)
          end)

        done_hit or live_hit
      end)
  end

  defp expanded?(nil, card), do: card.col == :in_progress
  defp expanded?("none", _card), do: false
  defp expanded?(expanded, card), do: is_binary(expanded) and expanded == card.doc_id

  # ── wave 21: the gantt maths (pure) ─────────────────────────────────────────
  #
  # The list IS the chart: the root + its family rows become gantt rows, each
  # with a bar from its creation to its close (done/cancelled) or to NOW.
  # Percentages are computed over the family's whole observed span, clamped so
  # a bar never escapes its track; a row with no creation stamp (a cold
  # broadcast projection) falls back to its update stamp — never a crash.
  defp gantt_data(card) do
    fam = (card[:family] && card.family.rows) || []

    base = [
      %{
        doc_id: card.doc_id,
        title: card.title,
        depth: 0,
        color_role: card.color_role,
        glyph: card.glyph,
        worker: card.worker,
        # the root's brief renders above the chart (never doubled); its
        # CRITERIA ride the chart as segment bars when the root is claimed
        # (wave 23) — the plain checklist hides while expanded.
        desc: nil,
        crits: (card.lifecycle_status == "in_progress" && card[:criteria_list]) || nil,
        created_at: card[:created_at],
        updated_at: card.updated_at
      }
      | fam
    ]

    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    starts =
      for row <- base, t = gantt_ts(row[:created_at]) || gantt_ts(row[:updated_at]), do: t

    origin_ts = Enum.min(starts, fn -> now end)
    span = max(now - origin_ts, 1)

    rows =
      Enum.map(base, fn row ->
        start_ts = gantt_ts(row[:created_at]) || gantt_ts(row[:updated_at]) || origin_ts

        end_ts =
          if row.color_role in [:done, :cancelled],
            do: gantt_ts(row[:updated_at]) || now,
            else: now

        left = clamp_pct((start_ts - origin_ts) / span * 100, 0.0, 97.0)
        width = clamp_pct(max((end_ts - start_ts) / span * 100, 2.0), 2.0, 100.0 - left)

        Map.merge(row, %{left: Float.round(left, 2), width: Float.round(width, 2)})
      end)

    %{rows: rows, origin: gantt_origin(base, origin_ts)}
  end

  defp gantt_origin(base, origin_ts) do
    Enum.find_value(base, fn row ->
      dt = row[:created_at] || row[:updated_at]
      if gantt_ts(dt) == origin_ts, do: dt
    end)
  end

  defp gantt_ts(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp gantt_ts(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp gantt_ts(_), do: nil

  defp clamp_pct(v, lo, hi), do: v |> max(lo) |> min(max(hi, lo)) |> Kernel.*(1.0)

  # The FIRST unmet criterion is "next" — the chip that pulses.
  defp next_unmet_index(crits), do: Enum.find_index(crits, &(!&1.met))

  # ── Render helpers ──────────────────────────────────────────────────────────

  # A lane (or the flat :all lane) is SETTLED when it has done work and zero
  # live pipeline — nothing open, ready, in flight, or blocked. Settled lanes
  # earn a receipt line instead of five columns of nothing. A lane with no
  # cards at all is NOT settled (there is nothing to receipt); the board-empty
  # state owns that.
  # The settled hero REPLACES the board with a done ledger, so anything not
  # counted here is a card that VANISHES. The thought columns count as live for
  # exactly that reason — a pipeline still weighing work is not "clear".
  defp lane_settled?(lane) do
    live =
      Enum.sum(
        for col <- [:open, :ready, :in_progress, :blocked, :considering, :researching],
            do: lane.counts[col] || 0
      )

    live == 0 and (lane.counts[:done] || 0) > 0
  end

  # The newest done card's timestamp — the organizer orders done newest-first,
  # so it is the head. Feeds the settled summary's "last <age>" stamp.
  defp newest_done_at(lane) do
    case lane.columns[:done] do
      [%{updated_at: at} | _] -> at
      _ -> nil
    end
  end

  # The settled hero's headline count: the honest full done_total when the
  # view is unfiltered, the visible slice's own count when a filter produced
  # the settled view (comparing a filtered slice against the global total
  # would overstate).
  defp settled_total(%{filtered?: true} = view, _board),
    do: view.lanes |> hd() |> Map.get(:columns, %{}) |> Map.get(:done, []) |> length()

  defp settled_total(_view, board), do: board.done_total

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

  @doc """
  A column atom's header label. TOTAL — the last clause is a fail-open
  humanizer, not decoration.

  This function had NO catch-all: every clause was an explicit atom, so the
  FIRST new column `Barkpark.Tasks.Board.columns/0` grew crashed the whole board
  render with `FunctionClauseError` (the header is drawn inside a
  `:for={col <- Board.columns()}` comprehension — one unlabelled atom takes down
  every column, not just its own). Adding a column must never be able to blank
  the board, so an unrecognised atom titlecases its own name and renders.

  Public because the catch-all is the CONTRACT and a regression test has to be
  able to hand it an atom no clause names — a column that does not exist yet is,
  by definition, unreachable through the render.
  """
  @spec col_label(atom()) :: String.t()
  def col_label(:open), do: "Open"
  def col_label(:ready), do: "Ready"
  def col_label(:in_progress), do: "In Progress"
  def col_label(:blocked), do: "Blocked"
  def col_label(:done), do: "Done"
  def col_label(:considering), do: "Considering"
  def col_label(:researching), do: "Researching"

  def col_label(col) when is_atom(col) do
    col
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # The column header's §1 ladder glyph. in_progress paints entirely from the
  # CSS `::before` spinner (same as the card glyph), so its span body is empty.
  # Fail-open like `col_label/1`: an unglyphed column draws the neutral dot
  # rather than an empty header (`Board.glyphs/0` is itself total).
  defp col_glyph(:in_progress), do: ""
  defp col_glyph(col), do: Board.glyphs()[col] || Board.glyphs()[:unknown]

  # in_progress renders its (animated) glyph entirely from CSS `::before`, so the
  # span body is empty — every other state prints the literal §1 Unicode char.
  defp glyph_text(%{color_role: :in_progress}), do: ""
  defp glyph_text(%{glyph: glyph}), do: glyph

  # A card's freshness stamp — coarse relative age ("now", "5m", "3h", "2d",
  # "6w") off `updated_at`. Coarse on purpose: it re-renders on every 15s
  # reconcile, so minute-level precision is honest and second-level would lie.
  defp age_label(%DateTime{} = dt),
    do: age_words(DateTime.diff(DateTime.utc_now(), dt))

  defp age_label(%NaiveDateTime{} = dt),
    do: age_words(NaiveDateTime.diff(NaiveDateTime.utc_now(), dt))

  defp age_label(_), do: nil

  defp age_words(s) when s < 60, do: "now"
  defp age_words(s) when s < 3_600, do: "#{div(s, 60)}m"
  defp age_words(s) when s < 86_400, do: "#{div(s, 3_600)}h"
  defp age_words(s) when s < 604_800, do: "#{div(s, 86_400)}d"
  defp age_words(s), do: "#{div(s, 604_800)}w"

  # The criteria progress row's fill width. total ≥ 1 by the organizer's
  # criteria projection contract, but guard the division anyway.
  defp crit_pct(%{met: met, total: total}) when total > 0, do: round(met / total * 100)
  defp crit_pct(_), do: 0

  # The card pill's tally: the WHOLE-subtree stats on a family card (wave 16),
  # the direct-children sub summary otherwise.
  defp family_tally(card) do
    case card[:family] do
      %{stats: stats} -> stats
      _ -> card[:sub]
    end
  end

  # An in-flight card's focus line — the step being worked RIGHT NOW (wave 12,
  # the TUI activity-focus read): the in-flight subtask (title + its worker)
  # when one exists, else the first unmet acceptance criterion. Nil renders no
  # line — the focus is never fabricated.
  defp focus_of(card) do
    case {card[:sub], card[:next_criterion]} do
      {%{active: %{title: title} = active}, _} when is_binary(title) ->
        %{title: title, worker: active[:worker]}

      {_, crit} when is_binary(crit) ->
        %{title: crit, worker: nil}

      _ ->
        nil
    end
  end

  # How many of a blocked card's blockers are still live (not yet done). The
  # organizer always projects `blocker_statuses` (broadcast cards carry the
  # previous card's forward), but read defensively — a missing key is 0, never
  # a crash.
  defp open_blockers(card) do
    card |> Map.get(:blocker_statuses, []) |> Enum.count(&(&1 != "done"))
  end

  # How many done tasks the capped ledger is NOT showing (flat, unfiltered view
  # only — a filtered count would compare a filtered slice against the full
  # done_total and overstate the window). The tally keeps the D10 promise
  # honest at the column level: the window never silently shrinks history.
  defp done_overflow(%{filtered?: true}, _board), do: 0

  defp done_overflow(view, _board) do
    lane = hd(view.lanes)
    shown = lane |> Map.get(:columns, %{}) |> Map.get(:done, []) |> length()
    max((lane[:done_total] || 0) - shown, 0)
  end

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
