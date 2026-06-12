defmodule BarkparkWeb.Studio.SheetGrid do
  @moduledoc """
  Studio grid editor for `type:"sheet"` documents (Sheets M2) — one
  `Phoenix.LiveComponent` owning the whole editing surface: the table grid,
  the formula bar + A1 name box, keyboard navigation with rectangular
  selection, TSV clipboard, row/column structure menus + resize, and the
  bottom tab strip.

  ## Wire protocol — edits are ops, state is deltas

  EVERY edit becomes a `Barkpark.Sheets.Session.apply_ops/3` call
  (server-side, no HTTP hop) and the component NEVER applies an op to its
  own assigns. The hosting StudioLive subscribes to the session delta topic
  (`Session.topic/3`) and forwards each `{:sheets_op, payload}` here via
  `send_update/3`: cell deltas merge into the local `content`; structural
  deltas (`payload.structure` — the changed map alone cannot re-key
  col_widths/merges/frozen bands) refetch the authoritative content via
  `Session.peek/2`. Own ops and remote edits ride the SAME path, so a
  second browser on the same sheet stays live by construction (M4 layers
  presence on top). Per-op errors (`cell_cap_exceeded`, bounds, …) surface
  as a transient notice.

  ## Rendering bounds

  No virtualization yet (future work): the grid renders the used range plus
  a margin, hard-capped at 500 rows with a "showing first 500" notice.
  Frozen rows/cols pin via CSS sticky, merges render as colspan/rowspan,
  `"s"` cell styles (b/i/bg/al) inline; engine error values (`#CYCLE!` …)
  and `"stale"` cells carry marker classes. Formula cells show the computed
  `"v"` in the grid and the `=`-prefixed `"f"` in the bar.

  The thin client half is `Hooks.SheetGrid`
  (`priv/static/assets/bp-sheet-grid.js`): keyboard map, clipboard TSV
  read/write, header resize drag, scroll-position keep. No grid/spreadsheet
  JS dependency (Golden Rule: no blocking scripts, LiveView-native).

  View mode (the header toggle) reuses the SAME `sheet_table/1` renderer
  minus every editing affordance — formula bar, hook, menus, resize handles
  and tab mutation buttons all drop away.

  ## Read-only hosting (M4 — the public reader)

  A host passing `read_only={true}` (the `/sheets/:slug` reader) gets the
  bare live grid: no document header, no formula bar, no hook, no menus, no
  active-cell highlight — the tab strip keeps ONLY its switch buttons. The
  guard is server-side too: `send_ops/2` drops every mutation while
  read-only, so a forged client event can never write through an
  unauthenticated mount. Deltas still apply (the host forwards
  `{:sheets_op, …}` exactly like StudioLive), so viewers watch edits live.

  ## Per-user undo/redo (M4)

  `send_ops/2` stamps the studio identity's `user_id` onto every op as
  `"user"`, so the session records per-user inverse stacks; the hook's
  Cmd/Ctrl+Z / Cmd/Ctrl+Shift+Z push `"undo"`/`"redo"` events that ride the
  same path as ops (`%{"op" => "undo", "user" => …}`). Empty-stack
  rejections surface as the transient notice like any other per-op error.

  ## Collaborator presence (M4)

  The hosting StudioLive tracks this user on the per-sheet presence topic
  (`Session.presence_topic/3` via `BarkparkWeb.Presence`) and passes the
  materialised list down as `presences` plus the topic and own `user_id`.
  This component OWNS the meta updates (same pid — components run in the LV
  process): the hook's client-throttled (~10/s) `presence-meta` frames carry
  the active cell + selection range; the `editing` flag is set on edit-start
  and cleared on commit/cancel — a soft lock, purely visual, LWW stands.
  Rendering: a collaborator's cursor cell gets a colored outline + name tag
  (emphasized while editing), selection ranges a translucent overlay; colors
  are the user's studio identity color (deterministic per user_id from
  `PresenceState`'s fixed palette when none is stored).
  """

  use BarkparkWeb, :live_component

  alias Barkpark.Content
  alias Barkpark.Sheets
  alias Barkpark.Sheets.Session
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.PresenceState

  # Render bounds (full virtualization is future work) + layout constants.
  @max_rows 500
  @max_cols 64
  @default_col_px 88
  @default_row_px 24
  @rowhead_px 44
  @headrow_px 25
  @engine_errors ["#VALUE!", "#DIV/0!", "#REF!", "#CYCLE!"]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       content: nil,
       rev: 0,
       tab: 0,
       active: {1, 1},
       anchor: nil,
       editing: nil,
       notice: nil,
       menu: nil,
       renaming_tab: nil,
       mode: :edit,
       read_only: false,
       user_id: nil,
       presence_topic: nil,
       presences: []
     )}
  end

  # A session delta forwarded by StudioLive's `{:sheets_op, …}` handle_info.
  @impl true
  def update(%{sheets_op: payload}, socket) do
    {:ok, apply_delta(socket, payload)}
  end

  def update(assigns, socket) do
    socket =
      assign(
        socket,
        Map.take(assigns, [:id, :doc, :dataset, :is_draft, :read_only, :user_id, :presence_topic, :presences])
      )

    if socket.assigns[:content] do
      {:ok, socket}
    else
      doc = assigns.doc
      slug = Content.published_id(doc.doc_id)

      # A live session's memory is authoritative; the persisted row backs
      # the cold open (same draft-first row the session itself loads).
      content =
        case Session.peek(slug, assigns.dataset) do
          {:ok, content} -> content
          {:error, :no_session} -> doc.content || %{}
        end

      {:ok, assign(socket, slug: slug, content: content)}
    end
  end

  # ── delta application ───────────────────────────────────────────────────

  defp apply_delta(socket, %{rev: rev} = payload) do
    cond do
      # Stale or duplicate frame (our own op's echo after a refetch).
      rev <= socket.assigns.rev ->
        socket

      # Structural ops re-key widths/heights/merges/frozen bands beyond the
      # changed-cells map; a rev gap means a missed frame. Both refetch.
      Map.has_key?(payload, :structure) or
          (socket.assigns.rev > 0 and rev > socket.assigns.rev + 1) ->
        refetch(socket, rev)

      true ->
        merge_changed(socket, payload)
    end
  end

  defp merge_changed(socket, %{rev: rev, tab: tab_idx, changed: changed}) do
    content = socket.assigns.content
    tabs = Map.get(content, "tabs") || []

    case Enum.at(tabs, tab_idx) do
      nil ->
        refetch(socket, rev)

      tab ->
        cells =
          Enum.reduce(changed, Map.get(tab, "cells") || %{}, fn
            {addr, nil}, acc -> Map.delete(acc, addr)
            {addr, cell}, acc -> Map.put(acc, addr, cell)
          end)

        tabs = List.replace_at(tabs, tab_idx, Map.put(tab, "cells", cells))
        assign(socket, content: Map.put(content, "tabs", tabs), rev: rev)
    end
  end

  defp refetch(socket, rev) do
    socket =
      case Session.peek(socket.assigns.slug, socket.assigns.dataset) do
        {:ok, content} -> assign(socket, content: content, rev: rev)
        {:error, :no_session} -> assign(socket, rev: rev)
      end

    # delete_tab may have removed the active tab — clamp.
    assign(socket, tab: min(socket.assigns.tab, max(length(tabs(socket)) - 1, 0)))
  end

  # ── events: selection + navigation ──────────────────────────────────────

  @impl true
  def handle_event("cell-click", %{"ref" => ref} = params, socket) do
    case Sheets.parse_ref(ref) do
      {:ok, pos} ->
        anchor = if params["shift"], do: socket.assigns.anchor || socket.assigns.active, else: nil
        {:noreply, assign(socket, active: pos, anchor: anchor, editing: nil, menu: nil)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("nav", %{"key" => key} = params, socket) do
    active = move(socket.assigns.active, key, dims(socket))
    anchor = if params["shift"], do: socket.assigns.anchor || socket.assigns.active, else: nil
    {:noreply, assign(socket, active: active, anchor: anchor, editing: nil, menu: nil)}
  end

  def handle_event("name-jump", %{"ref" => ref}, socket) do
    case Sheets.parse_ref(ref) do
      {:ok, pos} -> {:noreply, assign(socket, active: pos, anchor: nil)}
      :error -> {:noreply, socket}
    end
  end

  # ── events: cell editing ─────────────────────────────────────────────────

  def handle_event("edit-start", params, socket) do
    prefill =
      case params["seed"] do
        seed when is_binary(seed) and seed != "" -> seed
        _ -> raw_of(cell_at(socket, socket.assigns.active))
      end

    {:noreply,
     socket
     |> assign(editing: %{prefill: prefill}, menu: nil)
     |> push_presence(%{
       editing: Sheets.format_ref(socket.assigns.active),
       tab: socket.assigns.tab
     })}
  end

  def handle_event("edit-cancel", _params, socket) do
    {:noreply, socket |> assign(editing: nil) |> push_presence(%{editing: nil})}
  end

  def handle_event("edit-commit", %{"value" => value} = params, socket) do
    socket = commit(socket, socket.assigns.active, value)
    active = move(socket.assigns.active, move_key(params["move"]), dims(socket))

    {:noreply,
     socket
     |> assign(editing: nil, active: active, anchor: nil)
     |> push_presence(%{editing: nil})}
  end

  def handle_event("bar-commit", %{"value" => value}, socket) do
    {:noreply,
     socket
     |> commit(socket.assigns.active, value)
     |> assign(editing: nil)
     |> push_presence(%{editing: nil})}
  end

  def handle_event("clear-selection", _params, socket) do
    {c1, c2, r1, r2} = selection_rect(socket.assigns.active, socket.assigns.anchor)
    cells = Map.get(current_tab(socket), "cells") || %{}

    ops =
      for c <- c1..c2,
          r <- r1..r2,
          ref = Sheets.format_ref({c, r}),
          Map.has_key?(cells, ref) do
        %{"op" => "clear_cell", "tab" => socket.assigns.tab, "ref" => ref}
      end

    {:noreply, send_ops(socket, ops)}
  end

  # TSV paste starting at the active cell — values only; per-op errors
  # (cap, bounds) come back on the apply_ops reply as the notice.
  def handle_event("paste", %{"tsv" => tsv}, socket) when is_binary(tsv) do
    {c0, r0} = socket.assigns.active
    tab = socket.assigns.tab

    lines =
      case String.split(tsv, ["\r\n", "\n"]) do
        rows -> if List.last(rows) == "", do: Enum.drop(rows, -1), else: rows
      end

    ops =
      for {line, i} <- Enum.with_index(lines),
          {val, j} <- Enum.with_index(String.split(line, "\t")) do
        ref = Sheets.format_ref({c0 + j, r0 + i})

        if val == "" do
          %{"op" => "clear_cell", "tab" => tab, "ref" => ref}
        else
          %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => parse_raw(val)}
        end
      end

    {:noreply, send_ops(socket, ops)}
  end

  # ── events: collaborator presence (M4) ───────────────────────────────────

  # The hook's client-throttled (~10/s) cursor/selection frame. Refs are
  # validated server-side; a malformed frame degrades to nil rather than
  # erroring — presence is advisory, never load-bearing.
  def handle_event("presence-meta", params, socket) do
    active =
      with ref when is_binary(ref) <- params["active"],
           {:ok, pos} <- Sheets.parse_ref(ref) do
        Sheets.format_ref(pos)
      else
        _ -> nil
      end

    selection =
      case parse_range(params["selection"]) do
        {:ok, _} -> params["selection"]
        :error -> nil
      end

    {:noreply,
     push_presence(socket, %{active: active, selection: selection, tab: socket.assigns.tab})}
  end

  # ── events: structure (rows / cols / sizes) ─────────────────────────────

  def handle_event("menu-open", %{"kind" => kind, "index" => index}, socket) do
    key = {if(kind == "col", do: :col, else: :row), to_int(index)}
    {:noreply, assign(socket, menu: if(socket.assigns.menu == key, do: nil, else: key))}
  end

  def handle_event("menu-close", _params, socket) do
    {:noreply, assign(socket, menu: nil)}
  end

  def handle_event("rowcol-insert", %{"kind" => kind, "at" => at, "where" => where}, socket) do
    at = to_int(at) + if(where == "after", do: 1, else: 0)
    op = if kind == "col", do: "insert_cols", else: "insert_rows"

    {:noreply,
     socket
     |> assign(menu: nil)
     |> send_ops([%{"op" => op, "tab" => socket.assigns.tab, "at" => at, "count" => 1}])}
  end

  def handle_event("rowcol-delete", %{"kind" => kind, "at" => at}, socket) do
    op = if kind == "col", do: "delete_cols", else: "delete_rows"

    {:noreply,
     socket
     |> assign(menu: nil)
     |> send_ops([%{"op" => op, "tab" => socket.assigns.tab, "at" => to_int(at), "count" => 1}])}
  end

  def handle_event("resize", %{"kind" => kind, "index" => index, "px" => px}, socket) do
    op =
      case kind do
        "col" -> %{"op" => "set_col_width", "tab" => socket.assigns.tab, "col" => to_int(index), "px" => to_int(px)}
        "row" -> %{"op" => "set_row_height", "tab" => socket.assigns.tab, "row" => to_int(index), "px" => to_int(px)}
      end

    {:noreply, send_ops(socket, [op])}
  end

  # ── events: tab strip ────────────────────────────────────────────────────

  def handle_event("tab-switch", %{"tab" => idx}, socket) do
    {:noreply,
     socket
     |> assign(
       tab: to_int(idx),
       active: {1, 1},
       anchor: nil,
       editing: nil,
       menu: nil,
       renaming_tab: nil
     )
     |> push_presence(%{tab: to_int(idx), active: "A1", selection: nil, editing: nil})}
  end

  def handle_event("tab-add", _params, socket) do
    n = length(tabs(socket)) + 1
    {:noreply, send_ops(socket, [%{"op" => "add_tab", "name" => "Sheet #{n}"}])}
  end

  def handle_event("tab-rename-start", %{"tab" => idx}, socket) do
    {:noreply, assign(socket, renaming_tab: to_int(idx))}
  end

  def handle_event("tab-rename", %{"tab" => idx, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(renaming_tab: nil)
     |> send_ops([%{"op" => "rename_tab", "tab" => to_int(idx), "name" => name}])}
  end

  def handle_event("tab-delete", %{"tab" => idx}, socket) do
    {:noreply, send_ops(socket, [%{"op" => "delete_tab", "tab" => to_int(idx)}])}
  end

  # ── events: per-user undo/redo (M4) ──────────────────────────────────────

  # The hook's Cmd/Ctrl+Z / Cmd/Ctrl+Shift+Z. send_ops stamps the user, so
  # the session pops THIS identity's stack; the resulting delta re-renders
  # every client like any other op.
  def handle_event("undo", _params, socket) do
    {:noreply, send_ops(socket, [%{"op" => "undo"}])}
  end

  def handle_event("redo", _params, socket) do
    {:noreply, send_ops(socket, [%{"op" => "redo"}])}
  end

  # ── events: chrome ───────────────────────────────────────────────────────

  def handle_event("toggle-mode", _params, socket) do
    {:noreply,
     assign(socket,
       mode: if(socket.assigns.mode == :edit, do: :view, else: :edit),
       editing: nil,
       menu: nil
     )}
  end

  def handle_event("notice-dismiss", _params, socket) do
    {:noreply, assign(socket, notice: nil)}
  end

  # ── ops plumbing ─────────────────────────────────────────────────────────

  defp commit(socket, pos, value) do
    ref = Sheets.format_ref(pos)
    tab = socket.assigns.tab

    op =
      if String.trim(value) == "" do
        %{"op" => "clear_cell", "tab" => tab, "ref" => ref}
      else
        %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => parse_raw(value)}
      end

    send_ops(socket, [op])
  end

  # All mutations ride Session.apply_ops — the session recomputes,
  # broadcasts the delta (which updates this and every other client) and
  # debounce-persists. The component never mutates `content` here. Ops are
  # stamped with the studio identity's user_id so the session records
  # per-user undo stacks. Read-only hosts (the public reader) drop EVERY
  # mutation here — the server-side half of stripping the affordances.
  defp send_ops(socket, []), do: socket

  defp send_ops(%{assigns: %{read_only: true}} = socket, _ops), do: socket

  defp send_ops(socket, ops) do
    ops =
      case socket.assigns[:user_id] do
        user_id when is_binary(user_id) and user_id != "" ->
          Enum.map(ops, &Map.put_new(&1, "user", user_id))

        _ ->
          ops
      end

    case Session.apply_ops(socket.assigns.slug, socket.assigns.dataset, ops) do
      {:ok, %{errors: []}} ->
        assign(socket, notice: nil)

      {:ok, %{errors: [%{message: message} | _] = errors}} ->
        assign(socket, notice: "#{length(errors)} op(s) rejected: #{message}")

      {:error, reason} ->
        assign(socket, notice: "edit failed: #{inspect(reason)}")
    end
  end

  # The importer convention: a leading "=" means formula (passes through as
  # the string the session parses); otherwise numbers/booleans coerce so the
  # engine sees real scalars, everything else stays text.
  defp parse_raw("=" <> _ = value), do: value

  defp parse_raw(value) do
    case Integer.parse(value) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(value) do
          {f, ""} ->
            f

          _ ->
            case String.upcase(value) do
              "TRUE" -> true
              "FALSE" -> false
              _ -> value
            end
        end
    end
  end

  # ── collaborator presence (M4) ───────────────────────────────────────────

  # Merge `updates` into this user's meta on the sheet presence topic. The
  # hosting StudioLive tracked the entry (resub_sheet_presence) on THIS pid —
  # LiveComponents run in the LV process, so the update binds correctly.
  # No-op when presence isn't wired (disconnected render, read-only hosts).
  defp push_presence(socket, updates) do
    with topic when is_binary(topic) <- socket.assigns[:presence_topic],
         user_id when is_binary(user_id) <- socket.assigns[:user_id] do
      Presence.update(self(), topic, user_id, &Map.merge(&1, updates))
    end

    socket
  end

  # Collaborators on the CURRENT tab, self excluded; one entry per meta (a
  # user's second window is a second cursor). Colors normalize to the
  # deterministic palette when the meta carries a non-hex value — the color
  # lands in inline styles, so this is also the sanitizer.
  defp grid_peers(presences, user_id, tab) do
    for %{user_id: uid} = p <- presences || [],
        uid != user_id,
        Map.get(p, :tab, 0) == tab do
      %{
        name: Map.get(p, :name) || "User #{String.slice(uid, 0..3)}",
        color: peer_color(p, uid),
        active: Map.get(p, :active),
        selection: Map.get(p, :selection),
        editing: Map.get(p, :editing)
      }
    end
  end

  defp peer_color(p, uid) do
    case Map.get(p, :color) do
      color when is_binary(color) ->
        if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color),
          do: color,
          else: PresenceState.pick_color(uid)

      _ ->
        PresenceState.pick_color(uid)
    end
  end

  # `{cursor-cells, selection-cells}` for the rendered bounds:
  # `peer_active` maps {c, r} → peers whose cursor sits there (name tags +
  # outlines); `peer_sel` maps {c, r} → overlay colors. Ranges clip to the
  # rendered grid, out-of-bounds cursors drop.
  defp peer_maps(peers, cols, rows) do
    Enum.reduce(peers, {%{}, %{}}, fn peer, {act, sel} ->
      act =
        case cursor_pos(peer, cols, rows) do
          nil -> act
          pos -> Map.update(act, pos, [peer], &(&1 ++ [peer]))
        end

      sel =
        case parse_range(peer.selection) do
          {:ok, {c1, r1, c2, r2}} when c1 <= cols and r1 <= rows ->
            for c <- c1..min(c2, cols), r <- r1..min(r2, rows), reduce: sel do
              acc -> Map.update(acc, {c, r}, [peer.color], &(&1 ++ [peer.color]))
            end

          _ ->
            sel
        end

      {act, sel}
    end)
  end

  # The cursor cell — the `editing` ref when set (the emphasized soft-lock
  # tag follows the cell being edited), the active cell otherwise.
  defp cursor_pos(peer, cols, rows) do
    with ref when is_binary(ref) <- peer.editing || peer.active,
         {:ok, {c, r}} when c <= cols and r <= rows <- Sheets.parse_ref(ref) do
      {c, r}
    else
      _ -> nil
    end
  end

  # Per-cell presence decoration: outline shadow per cursor + translucent
  # fill per selection, both as inset box-shadows so they compose with the
  # cell's own background and never move layout.
  defp peer_deco(c, r, peer_active, peer_sel) do
    cursors = Map.get(peer_active, {c, r}, [])
    sel_colors = Map.get(peer_sel, {c, r}, [])

    shadows =
      Enum.map(cursors, &"inset 0 0 0 2px #{&1.color}") ++
        Enum.map(sel_colors, &"inset 0 0 0 9999px #{rgba(&1, 0.12)}")

    classes =
      if(cursors != [], do: " sheet-peer-cursor", else: "") <>
        if(sel_colors != [], do: " sheet-peer-sel", else: "")

    css = if shadows == [], do: "", else: " box-shadow: #{Enum.join(shadows, ", ")};"
    {classes, css}
  end

  defp rgba("#" <> hex, alpha) do
    [r, g, b] =
      for i <- [0, 2, 4], do: hex |> String.slice(i, 2) |> String.to_integer(16)

    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  defp td_style(base, ""), do: base
  defp td_style(nil, peer_css), do: peer_css
  defp td_style(base, peer_css), do: base <> peer_css

  # ── grid geometry ────────────────────────────────────────────────────────

  defp tabs(socket), do: Map.get(socket.assigns.content || %{}, "tabs") || []

  defp current_tab(socket),
    do: Enum.at(tabs(socket), socket.assigns.tab) || %{"name" => "Sheet 1", "cells" => %{}}

  defp cell_at(socket, pos) do
    cells = Map.get(current_tab(socket), "cells") || %{}
    Map.get(cells, Sheets.format_ref(pos))
  end

  defp dims(socket) do
    {cols, rows, _used} = grid_dims(current_tab(socket))
    {cols, rows}
  end

  defp grid_dims(tab) do
    {mc, mr} = used_bounds(tab)
    {min(max(mc + 2, 8), @max_cols), min(max(mr + 2, 20), @max_rows), mr}
  end

  defp used_bounds(tab) do
    cell_bounds =
      Enum.reduce(Map.get(tab, "cells") || %{}, {0, 0}, fn {addr, _cell}, {mc, mr} ->
        case Sheets.parse_ref(addr) do
          {:ok, {c, r}} -> {max(mc, c), max(mr, r)}
          :error -> {mc, mr}
        end
      end)

    Enum.reduce(Map.get(tab, "merges") || [], cell_bounds, fn m, {mc, mr} ->
      case parse_range(m) do
        {:ok, {_c1, _r1, c2, r2}} -> {max(mc, c2), max(mr, r2)}
        :error -> {mc, mr}
      end
    end)
  end

  defp parse_range(m) when is_binary(m) do
    with [a, b] <- String.split(m, ":"),
         {:ok, {c1, r1}} <- Sheets.parse_ref(a),
         {:ok, {c2, r2}} <- Sheets.parse_ref(b) do
      {:ok, {min(c1, c2), min(r1, r2), max(c1, c2), max(r1, r2)}}
    else
      _ -> :error
    end
  end

  defp parse_range(_), do: :error

  # `{anchor-spans, covered-cells}` for colspan/rowspan rendering, clipped
  # to the rendered bounds; degenerate (single-cell) merges drop.
  defp merge_maps(tab, cols, rows) do
    Enum.reduce(Map.get(tab, "merges") || [], {%{}, MapSet.new()}, fn m, {spans, covered} = acc ->
      case parse_range(m) do
        {:ok, {c1, r1, c2, r2}} when c1 <= cols and r1 <= rows ->
          c2 = min(c2, cols)
          r2 = min(r2, rows)

          if c2 > c1 or r2 > r1 do
            covered =
              for c <- c1..c2, r <- r1..r2, {c, r} != {c1, r1}, into: covered, do: {c, r}

            {Map.put(spans, {c1, r1}, {c2 - c1 + 1, r2 - r1 + 1}), covered}
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp selection_rect({c, r}, nil), do: {c, c, r, r}

  defp selection_rect({c1, r1}, {c2, r2}),
    do: {min(c1, c2), max(c1, c2), min(r1, r2), max(r1, r2)}

  defp move(pos, nil, _dims), do: pos

  defp move({c, r}, key, {cols, rows}) do
    case key do
      "ArrowUp" -> {c, max(r - 1, 1)}
      "ArrowDown" -> {c, min(r + 1, rows)}
      "ArrowLeft" -> {max(c - 1, 1), r}
      "ArrowRight" -> {min(c + 1, cols), r}
      "Home" -> {1, r}
      "End" -> {cols, r}
      "PageUp" -> {c, max(r - 20, 1)}
      "PageDown" -> {c, min(r + 20, rows)}
      _ -> {c, r}
    end
  end

  defp move_key("down"), do: "ArrowDown"
  defp move_key("right"), do: "ArrowRight"
  defp move_key("left"), do: "ArrowLeft"
  defp move_key(_), do: nil

  defp to_int(i) when is_integer(i), do: i

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _rest} -> i
      :error -> 0
    end
  end

  defp clamp_frozen(n, limit) when is_integer(n) and n > 0, do: min(n, limit)
  defp clamp_frozen(_n, _limit), do: 0

  # ── cell presentation ────────────────────────────────────────────────────

  defp raw_of(%{"f" => f}) when is_binary(f), do: "=" <> String.trim_leading(f, "=")
  defp raw_of(cell), do: display(cell)

  defp display(%{"v" => true}), do: "TRUE"
  defp display(%{"v" => false}), do: "FALSE"
  defp display(%{"v" => v}) when is_number(v), do: to_string(v)
  defp display(%{"v" => v}) when is_binary(v), do: v
  defp display(_cell), do: ""

  defp cell_class(c, r, {c1, c2, r1, r2}, active, cell) do
    classes = ["sheet-cell"]
    classes = if c >= c1 and c <= c2 and r >= r1 and r <= r2, do: ["sheet-sel" | classes], else: classes
    classes = if {c, r} == active, do: ["sheet-active" | classes], else: classes

    v = cell && Map.get(cell, "v")
    classes = if is_binary(v) and v in @engine_errors, do: ["sheet-err" | classes], else: classes
    classes = if cell && Map.get(cell, "stale") == true, do: ["sheet-stale" | classes], else: classes

    Enum.join(classes, " ")
  end

  defp col_px(col_widths, c), do: usable_px(Map.get(col_widths, Integer.to_string(c)), @default_col_px)
  defp row_px(row_heights, r), do: usable_px(Map.get(row_heights, Integer.to_string(r)), @default_row_px)

  defp usable_px(px, _default) when is_number(px) and px > 0, do: round(px)
  defp usable_px(_px, default), do: default

  defp left_px(c, col_widths),
    do: @rowhead_px + Enum.sum(for i <- 1..(c - 1)//1, do: col_px(col_widths, i))

  defp top_px(r, row_heights),
    do: @headrow_px + Enum.sum(for i <- 1..(r - 1)//1, do: row_px(row_heights, i))

  # Frozen bands pin via CSS sticky with computed px offsets; cell "s"
  # styles append last so a cell bg wins over the frozen backdrop.
  defp cell_style(c, r, fc, fr, col_widths, row_heights, cell) do
    sticky =
      cond do
        c <= fc and r <= fr ->
          "position: sticky; left: #{left_px(c, col_widths)}px; top: #{top_px(r, row_heights)}px; z-index: 2; background: var(--bg);"

        c <= fc ->
          "position: sticky; left: #{left_px(c, col_widths)}px; z-index: 2; background: var(--bg);"

        r <= fr ->
          "position: sticky; top: #{top_px(r, row_heights)}px; z-index: 1; background: var(--bg);"

        true ->
          ""
      end

    case sticky <> s_style(cell) do
      "" -> nil
      style -> style
    end
  end

  defp s_style(%{"s" => %{} = s}) do
    [
      if(Map.get(s, "b") == true, do: " font-weight: 600;", else: ""),
      if(Map.get(s, "i") == true, do: " font-style: italic;", else: ""),
      case Map.get(s, "bg") do
        bg when is_binary(bg) ->
          if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, bg), do: " background: #{bg};", else: ""

        _ ->
          ""
      end,
      case Map.get(s, "al") do
        al when al in ["left", "center", "right"] -> " text-align: #{al};"
        _ -> ""
      end
    ]
    |> Enum.join()
  end

  defp s_style(_cell), do: ""

  defp col_head_style(c, fc, col_widths) when c <= fc,
    do: "left: #{left_px(c, col_widths)}px; z-index: 5;"

  defp col_head_style(_c, _fc, _col_widths), do: nil

  defp row_head_style(r, fr, row_heights) when r <= fr,
    do: "top: #{top_px(r, row_heights)}px; z-index: 5;"

  defp row_head_style(_r, _fr, _row_heights), do: nil

  defp col_letters(c) when c <= 26, do: <<?A + c - 1>>
  defp col_letters(c), do: col_letters(div(c - 1, 26)) <> col_letters(rem(c - 1, 26) + 1)

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    all_tabs = Map.get(assigns.content || %{}, "tabs") || []
    tab = Enum.at(all_tabs, assigns.tab) || %{"name" => "Sheet 1", "cells" => %{}}
    {cols, rows, used_rows} = grid_dims(tab)
    cells = Map.get(tab, "cells") || %{}
    {spans, covered} = merge_maps(tab, cols, rows)
    col_widths = Map.get(tab, "col_widths") || %{}
    row_heights = Map.get(tab, "row_heights") || %{}

    {peer_active, peer_sel} =
      assigns.presences
      |> grid_peers(assigns.user_id, assigns.tab)
      |> peer_maps(cols, rows)

    assigns =
      assign(assigns,
        peer_active: peer_active,
        peer_sel: peer_sel,
        all_tabs: all_tabs,
        cols: cols,
        rows: rows,
        used_rows: used_rows,
        truncated: used_rows > @max_rows,
        cap_rows: @max_rows,
        cells: cells,
        spans: spans,
        covered: covered,
        col_widths: col_widths,
        row_heights: row_heights,
        frozen_cols: clamp_frozen(Map.get(tab, "frozen_cols"), cols),
        frozen_rows: clamp_frozen(Map.get(tab, "frozen_rows"), rows),
        # The reader strips the active-cell/selection highlight — {0, 0}
        # sits off the 1-based grid, so no cell matches.
        sel: if(assigns.read_only, do: {0, 0, 0, 0}, else: selection_rect(assigns.active, assigns.anchor)),
        grid_active: if(assigns.read_only, do: {0, 0}, else: assigns.active),
        active_ref: Sheets.format_ref(assigns.active),
        bar_value: raw_of(Map.get(cells, Sheets.format_ref(assigns.active))),
        editable: assigns.mode == :edit and not assigns.read_only
      )

    ~H"""
    <div
      id={@id}
      class={"editor-panel sheet-editor" <> if(@read_only, do: " sheet-reader", else: "")}
      data-test-id={if @read_only, do: "sheet-reader", else: "studio-sheet-editor"}
    >
      <.document_header :if={not @read_only} dataset={@dataset} title={@doc.title || @slug}>
        <:status_pill>
          <span class={"badge badge-#{if @is_draft, do: "draft", else: "published"}"}>
            <%= if @is_draft, do: "draft", else: "published" %>
          </span>
        </:status_pill>
        <:actions>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="toggle-mode"
            phx-target={@myself}
            data-test-id="sheet-mode-toggle"
          >
            <.icon name={if @editable, do: "eye", else: "pencil"} size={14} />
            <%= if @editable, do: "View", else: "Edit" %>
          </button>
        </:actions>
      </.document_header>

      <div :if={@editable} class="sheet-toolbar" data-test-id="sheet-toolbar">
        <form phx-submit="name-jump" phx-target={@myself}>
          <input
            name="ref"
            type="text"
            class="sheet-namebox-input"
            value={@active_ref}
            autocomplete="off"
            data-test-id="sheet-namebox"
          />
        </form>
        <form class="sheet-bar-form" phx-submit="bar-commit" phx-target={@myself}>
          <input
            name="value"
            type="text"
            class="sheet-bar-input"
            value={@bar_value}
            autocomplete="off"
            spellcheck="false"
            placeholder="Enter a value or =FORMULA"
            data-test-id="sheet-formula-bar"
          />
        </form>
      </div>

      <div :if={@notice} class="sheet-notice" data-test-id="sheet-notice">
        <span><%= @notice %></span>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="notice-dismiss" phx-target={@myself}>
          dismiss
        </button>
      </div>

      <div :if={@truncated} class="sheet-cap-notice" data-test-id="sheet-cap-notice">
        Showing the first <%= @cap_rows %> of <%= @used_rows %> rows.
      </div>

      <%= if @editable do %>
        <div id={"#{@id}-grid"} class="sheet-grid-wrap" phx-hook="SheetGrid" tabindex="0">
          <div class="sheet-scroll">
            <.sheet_table
              id={@id}
              cols={@cols}
              rows={@rows}
              cells={@cells}
              spans={@spans}
              covered={@covered}
              col_widths={@col_widths}
              row_heights={@row_heights}
              frozen_cols={@frozen_cols}
              frozen_rows={@frozen_rows}
              sel={@sel}
              active={@active}
              editing={@editing}
              menu={@menu}
              editable={true}
              myself={@myself}
              peer_active={@peer_active}
              peer_sel={@peer_sel}
            />
          </div>
        </div>
      <% else %>
        <div id={"#{@id}-grid-view"} class="sheet-grid-wrap">
          <div class="sheet-scroll">
            <.sheet_table
              id={"#{@id}-view"}
              cols={@cols}
              rows={@rows}
              cells={@cells}
              spans={@spans}
              covered={@covered}
              col_widths={@col_widths}
              row_heights={@row_heights}
              frozen_cols={@frozen_cols}
              frozen_rows={@frozen_rows}
              sel={@sel}
              active={@grid_active}
              editing={nil}
              menu={nil}
              editable={false}
              myself={nil}
              peer_active={@peer_active}
              peer_sel={@peer_sel}
            />
          </div>
        </div>
      <% end %>

      <div class="sheet-tabs" data-test-id="sheet-tabs">
        <%= for {t, i} <- Enum.with_index(@all_tabs) do %>
          <%= if @editable and @renaming_tab == i do %>
            <form phx-submit="tab-rename" phx-target={@myself} style="display: inline-flex;">
              <input type="hidden" name="tab" value={i} />
              <input
                name="name"
                type="text"
                value={Map.get(t, "name") || "Sheet #{i + 1}"}
                class="sheet-tab-rename-input"
                autocomplete="off"
                data-test-id="sheet-tab-rename-input"
              />
            </form>
          <% else %>
            <button
              type="button"
              class={"sheet-tab" <> if(i == @tab, do: " is-active", else: "")}
              phx-click="tab-switch"
              phx-dblclick={@editable && "tab-rename-start"}
              phx-value-tab={i}
              phx-target={@myself}
              data-test-id={"sheet-tab-#{i}"}
            >
              <%= Map.get(t, "name") || "Sheet #{i + 1}" %>
            </button>
          <% end %>
        <% end %>
        <%= if @editable do %>
          <button
            type="button"
            class="sheet-tab"
            phx-click="tab-add"
            phx-target={@myself}
            title="Add tab"
            data-test-id="sheet-tab-add"
          >+</button>
          <button
            type="button"
            class="sheet-tab"
            phx-click="tab-delete"
            phx-value-tab={@tab}
            phx-target={@myself}
            data-confirm="Delete this tab? Its cells are removed."
            title="Delete the active tab"
            data-test-id="sheet-tab-delete"
          >&times;</button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  The shared table renderer — the edit grid and the read-only View render
  the SAME markup; `editable={false}` drops every editing affordance
  (menus, resize handles, the in-cell input). Collaborator presence
  decorations (`peer_active` / `peer_sel`, see `peer_maps/3`) render in
  both modes and default empty for hosts that don't wire presence.
  """
  def sheet_table(assigns) do
    assigns =
      assigns
      |> assign_new(:peer_active, fn -> %{} end)
      |> assign_new(:peer_sel, fn -> %{} end)

    ~H"""
    <table class="sheet-table" data-test-id="sheet-table">
      <colgroup>
        <col style="width: 44px;" />
        <col :for={c <- 1..@cols} style={"width: #{col_px(@col_widths, c)}px;"} />
      </colgroup>
      <thead>
        <tr>
          <th class="sheet-corner"></th>
          <th
            :for={c <- 1..@cols}
            class="sheet-colhead"
            style={col_head_style(c, @frozen_cols, @col_widths)}
            data-c={c}
          >
            <%= col_letters(c) %>
            <%= if @editable do %>
              <button
                type="button"
                class="sheet-head-menu-btn"
                phx-click="menu-open"
                phx-value-kind="col"
                phx-value-index={c}
                phx-target={@myself}
                data-test-id={"sheet-colmenu-#{c}"}
              >&#9662;</button>
              <div :if={@menu == {:col, c}} class="sheet-menu" data-test-id="sheet-menu">
                <button type="button" phx-click="rowcol-insert" phx-value-kind="col" phx-value-at={c} phx-value-where="before" phx-target={@myself}>Insert left</button>
                <button type="button" phx-click="rowcol-insert" phx-value-kind="col" phx-value-at={c} phx-value-where="after" phx-target={@myself}>Insert right</button>
                <button type="button" phx-click="rowcol-delete" phx-value-kind="col" phx-value-at={c} phx-target={@myself}>Delete column</button>
              </div>
              <div class="sheet-rsz sheet-rsz--col" data-kind="col" data-index={c} data-px={col_px(@col_widths, c)}></div>
            <% end %>
          </th>
        </tr>
      </thead>
      <tbody>
        <tr :for={r <- 1..@rows} style={"height: #{row_px(@row_heights, r)}px;"}>
          <th
            class="sheet-rowhead"
            style={row_head_style(r, @frozen_rows, @row_heights)}
            data-r={r}
          >
            <%= r %>
            <%= if @editable do %>
              <button
                type="button"
                class="sheet-head-menu-btn"
                phx-click="menu-open"
                phx-value-kind="row"
                phx-value-index={r}
                phx-target={@myself}
                data-test-id={"sheet-rowmenu-#{r}"}
              >&#9662;</button>
              <div :if={@menu == {:row, r}} class="sheet-menu" data-test-id="sheet-menu">
                <button type="button" phx-click="rowcol-insert" phx-value-kind="row" phx-value-at={r} phx-value-where="before" phx-target={@myself}>Insert above</button>
                <button type="button" phx-click="rowcol-insert" phx-value-kind="row" phx-value-at={r} phx-value-where="after" phx-target={@myself}>Insert below</button>
                <button type="button" phx-click="rowcol-delete" phx-value-kind="row" phx-value-at={r} phx-target={@myself}>Delete row</button>
              </div>
              <div class="sheet-rsz sheet-rsz--row" data-kind="row" data-index={r} data-px={row_px(@row_heights, r)}></div>
            <% end %>
          </th>
          <%= for c <- 1..@cols, not MapSet.member?(@covered, {c, r}) do %>
            <% ref = col_letters(c) <> Integer.to_string(r) %>
            <% cell = Map.get(@cells, ref) %>
            <% span = Map.get(@spans, {c, r}) %>
            <% {peer_cls, peer_css} = peer_deco(c, r, @peer_active, @peer_sel) %>
            <td
              class={cell_class(c, r, @sel, @active, cell) <> peer_cls}
              data-ref={ref}
              data-r={r}
              data-c={c}
              data-v={display(cell)}
              colspan={span && elem(span, 0) > 1 && elem(span, 0)}
              rowspan={span && elem(span, 1) > 1 && elem(span, 1)}
              style={
                td_style(
                  cell_style(c, r, @frozen_cols, @frozen_rows, @col_widths, @row_heights, cell),
                  peer_css
                )
              }
            >
              <%= if @editable and @editing != nil and @active == {c, r} do %>
                <input
                  id={"#{@id}-cell-input"}
                  class="sheet-cell-input"
                  type="text"
                  value={@editing.prefill}
                  autocomplete="off"
                  spellcheck="false"
                  data-test-id="sheet-cell-input"
                />
              <% else %>
                <span class="sheet-cell-v"><%= display(cell) %></span>
              <% end %>
              <span
                :for={peer <- Map.get(@peer_active, {c, r}, [])}
                class={"sheet-peer-tag" <> if(peer.editing, do: " sheet-peer-editing", else: "")}
                style={"background: #{peer.color};"}
                data-test-id="sheet-peer-tag"
              ><%= peer.name %></span>
            </td>
          <% end %>
        </tr>
      </tbody>
    </table>
    """
  end
end
