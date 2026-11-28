defmodule BarkparkWeb.Studio.DeskLive do
  @moduledoc """
  The desk slice: a read-only desk beside the Studio, built to prove the
  TanStack Studio's pane navigation in LiveView. Plan:
  `/papers/desk-vertical-slice`.

  The whole pane chain is one URL segment in the TanStack and Sanity format
  (`BarkparkWeb.Studio.Desk.Panes`), read against the same desk tree the
  Studio and `GET /v1/structure/:dataset` serve
  (`BarkparkWeb.Studio.Desk.Tree`):

      /w/:ws/p/:proj/d/:dataset/studio/_desk/post;post-01

  Every row is a real link that patches. This page reads the URL and the
  tree and nothing else; each pane reads its own data
  (`BarkparkWeb.Studio.Desk.PaneComponent`), so a click builds only the pane
  it opens. The tree is built once per dataset and kept for the visit.

  The last document of the chain is edited by the Studio's own editor
  (`StudioLive` loads it and takes its events); the other panes are
  read-only. Workspace admins only while it is a slice; anyone else lands on
  the Studio.

  This module is the page: the URL, the tree, the panes in order, and the
  reads kept from a hover. The rest lives beside it, and the callbacks here
  hand over to it:

    * `BarkparkWeb.Studio.Desk.EditorHost`  the active document's editor
    * `BarkparkWeb.Studio.Desk.LiveRefresh` someone else saved
    * `BarkparkWeb.Studio.Desk.Style`       the desk's CSS
    * `BarkparkWeb.Studio.Desk.DocStyle`    the document pane's look (TanStack's)
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Structure
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.Bulk
  alias BarkparkWeb.Studio.Desk.DocClip
  alias BarkparkWeb.Studio.Desk.DocUndo
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.FieldActions
  alias BarkparkWeb.Studio.Desk.FocusMode
  alias BarkparkWeb.Studio.Desk.LeaveGuard
  alias BarkparkWeb.Studio.Desk.ListMenu
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.Desk.ListFirst
  alias BarkparkWeb.Studio.Desk.NewDocMenu
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.Studio.Desk.ScopeSwitch
  alias BarkparkWeb.Studio.Desk.Search
  alias BarkparkWeb.Studio.Desk.Style
  alias BarkparkWeb.Studio.Desk.TasksPanel
  alias BarkparkWeb.Studio.Desk.TasksRead
  alias BarkparkWeb.Studio.Desk.DocStyle
  alias BarkparkWeb.Studio.Desk.Text
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.Desk.Vision
  alias BarkparkWeb.Studio.Desk.VisionListen
  alias BarkparkWeb.Studio.StructureCopy
  alias BarkparkWeb.Studio.StudioLive.Handlers.ArrayItems
  alias BarkparkWeb.Studio.StudioLive.LeaveAsk
  alias BarkparkWeb.Studio.StudioLive.Paths
  alias BarkparkWeb.Studio.StudioLive.RejoinForm

  defmodule NotFound do
    @moduledoc "Raised for a desk URL that names nothing: its dataset segment is not text."
    defexception message: "no such dataset", plug_status: 404
  end

  # A dataset slug is at most 63 characters (`Tenancy.Dataset`); this leaves
  # room for an older, longer dataset string.
  @dataset_max 255

  # Longer than any desk URL. The web server bounds a request line; a live
  # patch and a hovered href come over the socket, which bounds neither.
  # Refused before it is read byte by byte (`Text.text_only/1`) and parsed.
  @splat_max 8_192

  @impl true
  def mount(%{"dataset" => dataset} = params, session, socket) do
    # A dataset segment with a byte the database refuses as text names no
    # dataset. Refused here, before the first read and before any redirect
    # that would carry it.
    # Nor does one longer than any name can be (the Studio's tabs would
    # compile it into a pattern: Regex.CompileError at 100,000 bytes).
    named?(dataset) || raise NotFound

    # The active document is edited by the Studio's own editor, so this page
    # mounts as the Studio does: the same state, capability gate and quota gate.
    {:ok, socket} = EditorHost.mount(params, session, socket)

    socket =
      socket
      |> assign_new(:scope_prefix, fn -> "" end)
      # The Studio's path before any document is loaded: a list's "Create
      # new" (J18) runs the Studio's `new-document` with no editor open yet.
      |> assign_new(:nav_path, fn -> [] end)
      |> assign(dataset: dataset, page_title: gettext("Desk"), desk_panes: [], desk: nil)
      # The tab reads "X | Barkpark", as the TanStack Studio's (J01 J02, R23).
      |> assign(:title_suffix, " | Barkpark")
      |> assign(warm: %{}, desk_focus: nil)
      |> assign(:titles, %{})
      # Each document's title as a list or a pane has read it, by id: a pane
      # drawn before its own read (a click, Back) is named by it, not its id.
      |> assign(:doc_titles, %{})
      # Each list type's sort as this editor keeps it (`ListMenu`).
      |> then(&assign(&1, :list_sorts, ListMenu.prefs(&1, dataset)))
      |> assign(:desk_inspect, false)
      # The question before leaving a held field (`LeaveGuard`): not asked.
      |> assign(desk_leave: nil, desk_leave_pass: false)
      |> attach_hook(:desk_leave, :after_render, &leave_follow/1)
      # The desk's own tool in place of the panes (`Vision`), from the URL.
      |> assign(:desk_tool, nil)
      # The navbar's workspace, project and dataset card (`ScopeSwitch`): closed.
      |> assign(:desk_scope, nil)
      # A rejoin after the socket dropped: its first render must hold the
      # open document's editor, or the join patch drops the one the browser
      # has, with what was typed offline (task-2f3d3e3835f2a755).
      |> assign(:desk_rejoin?, rejoin?(connected?(socket) && get_connect_params(socket)))
      # The same rejoin, for the editor's top-level rich text: read against
      # the digest the page kept (`TextConfirmed.loaded/1`).
      |> assign(:editor_rejoined?, rejoin?(connected?(socket) && get_connect_params(socket)))
      # The form generation the page's editor was drawn at (`RejoinForm`).
      |> assign(
        :editor_rejoin_form,
        RejoinForm.from_params(connected?(socket) && get_connect_params(socket))
      )
      |> Bulk.init()
      # The navbar's Tasks sidebar (`TasksPanel`): offered while the Tasks
      # plugin is on for the workspace, closed until its button is pressed.
      |> assign(:desk_tasks?, TasksRead.available?(socket.assigns[:current_workspace]))
      |> assign(:desk_tasks_open?, false)
      # The search's hits: up to 50, as the TanStack Studio's text search,
      # the first 40 drawn, then more as the list's end scrolls near (`Search`).
      |> assign(desk_search_limit: Search.limit(), desk_search_drawn: Search.step())
      |> LiveRefresh.init()

    if socket.assigns[:shares_admin?] do
      {:ok, socket}
    else
      {:ok,
       push_navigate(socket, to: Paths.studio_path(socket.assigns.scope_prefix, [], dataset))}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    # A held field asks before the document is put away (`LeaveGuard`): the
    # panes and the editor stay as they are, the URL already moved.
    if LeaveGuard.ask?(socket) and not LeaveGuard.keeps?(socket, params) do
      {:noreply, LeaveGuard.ask(socket, {:patch, params, uri})}
    else
      socket = assign(socket, desk_leave: nil, desk_leave_pass: false)
      {:noreply, socket} = route(params, uri, socket)
      # Vision's Listen ends when Vision is left or the page's dataset changes.
      {:noreply, VisionListen.follow(socket)}
    end
  end

  defp route(params, uri, socket) do
    cond do
      # A live patch to such a dataset segment goes back to the desk it left.
      # So does one to a dataset longer than any name can be.
      not named?(params["dataset"] || socket.assigns.dataset) ->
        {:noreply, redirect(socket, to: socket.assigns.base)}

      # So does one to a pane splat past the cap; a first request for one
      # names nothing.
      splat_bytes(params) > @splat_max ->
        if base = socket.assigns[:base],
          do: {:noreply, redirect(socket, to: base)},
          else: raise(NotFound)

      # The desk's Vision: the desk's page with the query tool for its panes.
      params["panes"] == ["_tools", "vision"] ->
        {:noreply, socket} = follow(Map.delete(params, "panes"), uri, socket)

        {:noreply,
         assign(socket,
           desk_tool: :vision,
           page_title: gettext("Vision"),
           vision_datasets: Vision.datasets(socket.assigns)
         )}

      true ->
        follow(params, uri, socket)
    end
  end

  # Joined as `follow/3` joins it, so it takes what that takes.
  defp named?(dataset), do: Text.text?(dataset) and byte_size(dataset) <= @dataset_max

  defp splat_bytes(params), do: params |> Map.get("panes", []) |> Enum.join("/") |> byte_size()

  defp follow(params, uri, socket) do
    dataset = params["dataset"] || socket.assigns.dataset
    # The router hands the splat over as decoded path segments; a param value
    # with a slash in it (`inspect=sanity/structure/history`) spans several.
    splat = params |> Map.get("panes", []) |> Enum.join("/") |> Text.text_only()
    scope = ScopeHelpers.scope_opts(socket)
    desk = desk(socket.assigns.desk, dataset, scope)
    panes = Tree.parse(splat, desk.root)
    desk = expand_open(desk, panes, dataset, scope)

    nodes = Tree.nodes_of(panes, desk.root, desk.nodes)

    views =
      for {{pane, node}, index} <- panes |> Enum.zip(nodes) |> Enum.with_index() do
        %{
          id: "desk-pane-#{index}-#{Panes.pane_key(pane)}",
          pane: pane,
          index: index,
          node: node,
          key: PaneComponent.data_key(pane, dataset, node),
          title: known_title(socket, pane) || PaneComponent.provisional_title(pane, node)
        }
      end

    views = Enum.map(views, &Map.put(&1, :follows, leader(&1, views)))
    base = Paths.studio_path(socket.assigns.scope_prefix, ["_desk"], dataset)
    # A pane that stays does not read again, so the title it read is kept here.
    titles = Map.take(socket.assigns.titles, Enum.map(views, & &1.id))
    last = List.last(views)
    # Following a hit (or any link) puts the search away. The Inspect dialog
    # is open while the URL says so (`inspect=on` on the last document, as
    # Sanity's), so Back after closing it opens it again.
    socket =
      assign(socket,
        desk_search: "",
        desk_search_hits: [],
        desk_inspect: match?(%{kind: :doc, inspect: "on"}, List.last(panes))
      )

    # Focus mode is for the panes it was turned on over (`FocusMode`).
    socket = FocusMode.follow(socket, splat)

    socket =
      socket
      |> LiveRefresh.subscribe(dataset)
      |> assign(
        dataset: dataset,
        desk: desk,
        scope: scope,
        chain: panes,
        desk_panes: views,
        base: base,
        # `Shared.studio_path/4` prints the Studio's own navigation as desk URLs.
        desk_base: base,
        desk_uri: uri,
        desk_tool: nil,
        vision_datasets: [],
        titles: titles,
        page_title: titles[last.id] || kept_title(socket.assigns, last) || last.title
      )

    # A list's selection lives as long as its pane, in its dataset (`Bulk`).
    socket = Bulk.follow(socket, views)

    # The lists' first pages: read in the first render, handed to the
    # connected mount (ruling R12).
    socket = ListFirst.warm(socket, views)
    socket = EditorHost.follow(socket, panes, dataset)

    # A connected page loads the pending document here, so the patch draws
    # its editor: the browser has already answered the click with a frame
    # (`bp-desk.js`), and a frame from the server in between was a second,
    # different pane for a moment (a read-only copy of the form when the row
    # had been hovered). A rejoin's first patch does the same, so the join
    # render holds its editor in place (`rejoin?/1`). The first, unconnected
    # render only draws the frame: the connected mount loads the document.
    {rejoin?, socket} =
      {socket.assigns[:desk_rejoin?] == true, assign(socket, :desk_rejoin?, false)}

    # Only the document the rejoin's first patch loads is the page's own
    # (`TextConfirmed.loaded/1`); one opened later is drawn anew.
    socket =
      if rejoin? and socket.assigns.pending != nil,
        do: socket,
        else: socket |> assign(:editor_rejoined?, false) |> RejoinForm.forget()

    case socket.assigns.pending do
      nil ->
        {:noreply, socket}

      target when rejoin? ->
        EditorHost.edit(socket, target)

      target ->
        if connected?(socket),
          do: EditorHost.edit(socket, target),
          else: {:noreply, socket}
    end
  end

  # `_mounts` is a connect param LiveView sets itself (phoenix_live_view
  # 1.1.33: `connectParams` in phoenix_live_view.js; one of the "reserved
  # params" in the `Phoenix.LiveView` docs): the times this view has mounted,
  # 0 on its first join, counting up on each reconnect. An upgrade that drops
  # it makes every join a first one: the deferred load, as before.
  @doc false
  def rejoin?(%{"_mounts" => n}) when is_integer(n) and n > 0, do: true
  def rejoin?(_connect_params), do: false

  # The same last pane after a patch that changed only its params (Inspect,
  # a view tab): the title it has is kept. The edit pane's title comes from
  # the editor, which a param change does not load again.
  defp kept_title(%{desk_panes: [_ | _] = views, page_title: title}, last),
    do: if(List.last(views).id == last.id, do: title)

  defp kept_title(_assigns, _last), do: nil

  defp known_title(socket, %{kind: :doc, id: id}), do: socket.assigns.doc_titles[id]
  defp known_title(_socket, _pane), do: nil

  # A row was hovered or focused (`bp-desk.js`): read the pane it opens now,
  # so the click that follows opens it with its data. Kept for a short while
  # and for a few panes only; a pane never shows a read older than that. The
  # while is counted from the hover, as `bp-desk.js` counts when it forgets
  # the row: counted from the landing, a slow read would refuse the next hover.
  @warm_ttl_ms 30_000
  @warm_cap 8

  @impl true
  def handle_event("warm", %{"href" => href}, socket) when is_binary(href) do
    %{base: base, desk: desk, dataset: dataset, scope: scope, warm: warm} = socket.assigns

    with true <- String.starts_with?(href, base <> "/"),
         true <- byte_size(href) - byte_size(base) <= @splat_max,
         splat = href |> String.replace_prefix(base <> "/", "") |> Text.text_only(),
         chain = Tree.parse(splat, desk.root),
         last = List.last(chain),
         # A list in the sort its pane will read in: the pane takes this read.
         sort = ListMenu.kept(socket.assigns.list_sorts, desk.menus, last[:type]),
         pane = PaneComponent.with_query(last, chain, length(chain) - 1, Rows.page(), sort),
         true <- pane.kind in [:list, :doc],
         node = chain |> Tree.nodes_of(desk.root, desk.nodes) |> List.last(),
         key = PaneComponent.data_key(pane, dataset, node) do
      now = System.monotonic_time(:millisecond)
      hovered = assign(socket, :warm, Map.put(warm, key, {:reading, now}))

      cond do
        # Still out: nothing to read, but the row was hovered again just now.
        reading?(warm[key]) ->
          {:noreply, hovered}

        # A read a pane may still show: no need to read again.
        warm[key] && fresh?(warm[key], now) ->
          {:noreply, socket}

        true ->
          read =
            PaneComponent.in_locale(fn ->
              PaneComponent.read_pane(pane, node, dataset, scope, :warm)
            end)

          {:noreply, start_async(hovered, {:warm, key}, read)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("warm", _params, socket), do: {:noreply, socket}

  # The edit pane's focus mode button (J26).
  def handle_event("desk-focus", %{"index" => index}, socket),
    do: {:noreply, FocusMode.toggle(socket, index)}

  # The search box (`Search`): each new set of hits is drawn from its first 40.
  def handle_event("desk-search", params, socket) do
    {:noreply, socket} = EditorHost.handle_event("desk-search", params, socket)
    {:noreply, assign(socket, :desk_search_drawn, Search.step())}
  end

  # Leaving a held field (`LeaveGuard`). Create new asks before anything is
  # made; a link that leaves the page comes from `bp-desk.js`.
  def handle_event("new-document", params, socket) when is_map_key(params, "type") do
    if LeaveGuard.ask?(socket),
      do: {:noreply, LeaveGuard.ask(socket, {:event, "new-document", params})},
      else:
        DocUndo.around(
          "new-document",
          params,
          socket,
          &EditorHost.handle_event("new-document", params, &1)
        )
  end

  # A link `bp-desk.js` held back while a field is held: a desk link that
  # keeps the document goes on; any other asks. Its kind is its LiveView
  # link's (`data-phx-link`): "patch", "redirect", or none, a page load.
  def handle_event("desk-leave", %{"href" => href} = params, socket) do
    local? = LeaveGuard.local?(href)
    kind = if local?, do: LeaveGuard.kind(socket, href, params["kind"]), else: params["kind"]
    params = Map.put(params, "kind", kind)

    cond do
      not local? ->
        {:noreply, socket}

      kind == "patch" and (not LeaveGuard.ask?(socket) or LeaveGuard.keeps_path?(socket, href)) ->
        {:noreply, push_patch(socket, to: href)}

      kind == "patch" ->
        {:noreply, LeaveGuard.ask(socket, {:event, "desk-leave", params})}

      # The hold ended on the way: the link goes, as it would have.
      not LeaveGuard.ask?(socket) ->
        {:noreply,
         if(kind == "redirect",
           do: push_navigate(socket, to: href),
           else: redirect(socket, to: href)
         )}

      true ->
        {:noreply,
         LeaveGuard.ask(socket, {:link, href, if(kind == "redirect", do: :redirect, else: :page)})}
    end
  end

  # Stay: the URL goes back to the document, and `bp-desk.js` puts the caret
  # back where it was.
  def handle_event("desk-leave-stay", _params, socket) do
    socket =
      case socket.assigns.desk_leave do
        # Back moved the URL: a new entry for the document puts history as
        # it was before the press.
        %{to: {:patch, _, _}, back: back} -> push_patch(socket, to: back)
        _ -> socket
      end

    {:noreply, socket |> assign(:desk_leave, nil) |> push_event("bp:desk-leave-stayed", %{})}
  end

  # Leave: what was asked goes on, past the guard once. A press passed every
  # handle_event hook when it was made (LiveScope's grant gates, Caps, the
  # quota gate, …); it passes them again here, as a grant may have gone
  # while the question was open (`LeaveAsk.hooks/3`, task-91730f627f3b7fdb).
  def handle_event("desk-leave-go", _params, socket) do
    socket = assign(socket, desk_leave_pass: true)

    case socket.assigns.desk_leave do
      %{to: {:patch, params, uri}} ->
        handle_params(params, uri, socket)

      %{to: {:event, event, params}} ->
        socket = assign(socket, :desk_leave, nil)

        socket =
          case LeaveAsk.hooks(event, params, socket) do
            {:cont, socket} ->
              {:noreply, socket} = handle_event(event, params, socket)
              socket

            {:halt, socket} ->
              socket
          end

        # The pass is for the patch the event sent; with none, it ends here.
        {:noreply,
         if(socket.redirected, do: socket, else: assign(socket, :desk_leave_pass, false))}

      _ ->
        {:noreply, assign(socket, desk_leave: nil, desk_leave_pass: false)}
    end
  end

  # The hits' end scrolled near (`phx-viewport-bottom`): 40 more drawn.
  def handle_event("desk-search-more", _params, socket) do
    drawn = socket.assigns.desk_search_drawn + Search.step()
    {:noreply, assign(socket, :desk_search_drawn, min(drawn, Search.limit()))}
  end

  # Enter opens the lit hit, or searches what was
  # typed if its hits are not in yet. The arrows move the light in the
  # browser (`bp-desk.js`), which sends its index with the form as `lit`.
  def handle_event("desk-search-open", %{"value" => value} = params, socket) do
    %{desk_search: typed, desk_search_hits: hits} = socket.assigns

    case value == typed && Enum.at(hits, lit(params["lit"], hits)) do
      # Opened from the keys: its first field takes the focus, as the
      # TanStack Studio's (`bp-desk.js` waits for the editor).
      %{} = hit ->
        to = Search.href(socket.assigns.base, socket.assigns.desk.root, hit)

        if LeaveGuard.ask?(socket) and not LeaveGuard.keeps_path?(socket, to),
          do: {:noreply, LeaveGuard.ask(socket, {:event, "desk-search-open", params})},
          else:
            {:noreply,
             socket |> push_patch(to: to) |> push_event("bp:focus-new-doc", %{id: hit.id})}

      _ ->
        handle_event("desk-search", params, socket)
    end
  end

  # Everything else is the editor's: the Studio's own handlers.
  # Ctrl+Alt+I while a document is open, and the dialog's close (`bp-desk.js`):
  # `inspect=on` in, or out of, the last document's URL. Only over a document
  # the editor holds: the dialog renders that one.
  def handle_event("desk-inspect", %{"open" => open}, socket) do
    %{chain: panes, base: base} = socket.assigns
    last = List.last(panes)

    to =
      &push_patch(socket, to: Panes.with_params(panes, length(panes) - 1, %{inspect: &1}, base))

    cond do
      open == true and is_map(socket.assigns[:editor_doc]) and match?(%{kind: :doc}, last) ->
        {:noreply, to.("on")}

      open != true and match?(%{inspect: "on"}, last) ->
        {:noreply, to.(nil)}

      true ->
        {:noreply, assign(socket, :desk_inspect, false)}
    end
  end

  # A typed edit of the form: the editor's, and a step of the document's
  # undo when it landed (`DocUndo`).
  def handle_event("autosave" = event, params, socket),
    do:
      DocUndo.around(event, params, socket, fn socket ->
        EditorHost.handle_event(event, params, socket)
      end)

  # The document's undo and redo, Mod+Z and Shift+Mod+Z (`DocUndo`).
  def handle_event("desk-undo", params, socket), do: DocUndo.handle_event(params, socket)

  # A field's "Field actions" menu (`FieldActions`).
  def handle_event("desk-field-" <> _ = event, params, socket),
    do: FieldActions.handle_event(event, params, socket)

  # The header menu's Copy document and Paste document (`DocClip`).
  def handle_event("desk-doc-" <> _ = event, params, socket),
    do: DocClip.handle_event(event, params, socket)

  # An array item's Copy (`Handlers.ArrayItems`): it writes nothing.
  def handle_event("desk-item-copy", params, socket),
    do: ArrayItems.copy(params, socket)

  # A list's selection and its bulk publish and unpublish (`Bulk`). They are
  # the page's events, so the Studio's capability gate has passed them.
  def handle_event("bulk-" <> _ = event, params, socket),
    do: Bulk.handle_event(event, params, socket)

  # The navbar's and the drawer's Tasks button (`TasksPanel`).
  def handle_event("desk-tasks-toggle", _params, socket) do
    if socket.assigns.desk_tasks?,
      do: {:noreply, assign(socket, :desk_tasks_open?, !socket.assigns.desk_tasks_open?)},
      else: {:noreply, socket}
  end

  # The navbar's workspace, project and dataset switcher (`ScopeSwitch`).
  def handle_event("desk-scope-" <> _ = event, params, socket),
    do: ScopeSwitch.handle_event(event, params, socket)

  # Vision's Listen and its Stop (`VisionListen`).
  def handle_event("vision-listen-" <> _ = event, params, socket),
    do: VisionListen.handle_event(event, params, socket)

  # The rest is the editor's; a list's buttons (`array_op`) are a step of the
  # document's undo when they landed (`DocUndo`).
  def handle_event(event, params, socket),
    do:
      DocUndo.around(event, params, socket, fn socket ->
        EditorHost.handle_event(event, params, socket)
      end)

  # The lit hit's index from the form: one of the hits, else the first.
  defp lit(index, hits) do
    case Integer.parse(to_string(index)) do
      {i, ""} when i >= 0 and i < length(hits) -> i
      _ -> 0
    end
  end

  @impl true
  def handle_async({:warm, key}, {:ok, data}, socket) do
    now = System.monotonic_time(:millisecond)

    case socket.assigns.warm[key] do
      {:reading, hovered} ->
        warm =
          socket.assigns.warm
          |> Map.put(key, {data, hovered})
          |> Enum.filter(fn {_key, entry} -> fresh?(entry, now) end)
          |> Enum.sort_by(
            fn {_key, entry} -> if reading?(entry), do: now, else: elem(entry, 1) end,
            :desc
          )
          |> Enum.take(@warm_cap)
          |> Map.new()

        {:noreply, assign(socket, :warm, warm)}

      # Dropped while it was out (someone saved): it may be older than the save.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_async({:warm, key}, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :warm, Map.delete(socket.assigns.warm, key))}

  # A bulk publish or unpublish is back (`Bulk`).
  def handle_async({:desk_bulk, task}, result, socket),
    do: Bulk.handle_async(task, result, socket)

  defp account_path(%{scope_prefix: prefix, dataset: dataset})
       when is_binary(prefix) and prefix != "" and is_binary(dataset),
       do: Paths.studio_path(prefix, ["_account"], dataset)

  defp account_path(_assigns), do: nil

  defp fresh?({:reading, _hovered}, _now), do: true
  defp fresh?({_data, at}, now), do: now - at < @warm_ttl_ms

  defp reading?(entry), do: match?({:reading, _hovered}, entry)

  defp warm(warm, key) do
    case warm[key] do
      {%{} = data, at} -> if fresh?({data, at}, System.monotonic_time(:millisecond)), do: data
      _ -> nil
    end
  end

  @impl true
  def handle_info({:document_changed, %{type: _, doc_id: _} = msg}, socket),
    do: {:noreply, LiveRefresh.changed(socket, msg)}

  # A read kept from a hover may be older than the save: drop them all.
  def handle_info(:desk_refresh, socket),
    do: {:noreply, socket |> LiveRefresh.refresh() |> assign(:warm, %{})}

  # A pane's read landed: the tab title follows the last pane's real title.
  # The pane is named by its id, not its place: a title that lands after a
  # click replaced its pane is no longer anyone's.
  def handle_info({:desk_pane_title, id, title}, socket) when is_binary(title) do
    panes = socket.assigns.desk_panes

    case Enum.find(panes, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      view ->
        socket = assign(socket, :titles, Map.put(socket.assigns.titles, id, title))

        if view.index == length(panes) - 1,
          do: {:noreply, assign(socket, :page_title, title)},
          else: {:noreply, socket}
    end
  end

  # A list's menu picked a sort: it sticks for the type, here and for this editor.
  # Titles a list or a document pane has read (`PaneComponent`). Kept for the
  # session's panes to come; a desk that has read more than @doc_titles_cap
  # starts over from the latest read.
  @doc_titles_cap 5_000
  def handle_info({:desk_doc_titles, titles}, socket) when is_map(titles) do
    known = Map.merge(socket.assigns.doc_titles, titles)
    known = if map_size(known) > @doc_titles_cap, do: titles, else: known
    {:noreply, assign(socket, :doc_titles, known)}
  end

  # A list pane says which rows a tick or a Shift-click names (`Bulk.pick/2`).
  # Nothing is written: the page keeps the selection.
  def handle_info({:desk_bulk_pick, pane, mode, ids, last}, socket),
    do: {:noreply, Bulk.picked(socket, pane, mode, ids, last)}

  def handle_info({:desk_list_sort, type, sort}, socket) when is_binary(type) do
    # Only a sort the type offers is kept (the pane checked it too).
    sort = ListMenu.pick(sort, (socket.assigns.desk.menus[type] || %{sorts: []}).sorts)
    :ok = ListMenu.remember(socket, socket.assigns.dataset, type, sort)

    sorts =
      if sort,
        do: Map.put(socket.assigns.list_sorts, type, sort),
        else: Map.delete(socket.assigns.list_sorts, type)

    # A read of the type's list kept from ahead of the pick is in the old
    # order: the re-drawn pane would take it in place of its own sorted read.
    warm = Map.reject(socket.assigns.warm, fn {{_pane, t, _ds, _filter}, _} -> t == type end)

    {:noreply, assign(socket, list_sorts: sorts, warm: warm)}
  end

  # A change Vision's Listen may show (`VisionListenStream`).
  def handle_info({:vision_listen, _ref, _message} = message, socket),
    do: VisionListen.handle_info(message, socket)

  # A pick or a Remove in a tree codelist (`TreeCodelistField`) comes as a
  # message, and is a step of the document's undo when it landed, as a typed
  # edit is (`DocUndo`, task-a895a60bcc1302d9).
  def handle_info({:tree_codelist_pick, %{} = msg} = message, socket),
    do:
      DocUndo.around("tree_codelist_pick", msg, socket, fn socket ->
        EditorHost.handle_info(message, socket)
      end)

  # The hold ended while the question was open: it closes, as Stay.
  def handle_info(:desk_leave_cleared, socket) do
    if socket.assigns.desk_leave && is_nil(LeaveGuard.doc(socket.assigns)),
      do: handle_event("desk-leave-stay", %{}, socket),
      else: {:noreply, socket}
  end

  def handle_info(message, socket), do: EditorHost.handle_info(message, socket)

  # After each render (`LeaveGuard.follow/1`): a local capture, so the
  # receipt census reads the hook (LIVEVIEW-HOOK-FN-RESOLVES).
  defp leave_follow(socket), do: LeaveGuard.follow(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Style.sheet />
    <DocStyle.sheet />
    <BarkparkWeb.Studio.Desk.NavbarStyle.sheet />
    <BarkparkWeb.Studio.Desk.NavDrawerStyle.sheet />
    <BarkparkWeb.Studio.Desk.VisionStyle.sheet :if={@desk_tool == :vision} />
    <BarkparkWeb.Studio.Desk.TasksStyle.sheet :if={@desk_tasks?} />
    <div
      class="dk dk-tasks-host"
      data-tasks-open={@desk_tasks_open?}
      style="flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column"
    >
    <%!-- The navbar's Tasks sidebar (`TasksPanel`), at the right of the panes. --%>
    <.live_component
      :if={@desk_tasks_open?}
      module={TasksPanel}
      id="dk-tasks"
      dataset={@dataset}
      workspace_id={@current_workspace.id}
      project_id={assigns[:current_project] && assigns[:current_project].id}
      target={active_doc_id(@active, assigns[:editor_doc])}
      base={@base}
      root={@desk.root}
    />
    <%!-- The search is a dialog, as the TanStack Studio's: the navbar's
          search button (`data-desk-search-open`), Cmd+K and "/" open it
          (`bp-desk.js`). A patch keeps it open: `open` is the browser's. --%>
    <dialog
      id="dk-search-dialog"
      class="dk-search-dialog"
      aria-label={gettext("Search documents")}
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
    >
      <Search.box
        query={@desk_search}
        hits={@desk_search_hits}
        drawn={@desk_search_drawn}
        root={@desk.root}
        base={@base}
      />
    </dialog>
    <%!-- In a box of its own: drawn among the desk's own children, the
          question moved `#desk-panes` in the DOM and the pane lost its
          scroll (`LeaveGuard`). --%>
    <div id="dk-leave-host">
      <LeaveGuard.dialog :if={@desk_leave} id="dk-leave-dialog" leave={@desk_leave} message={LeaveGuard.message(assigns)} />
    </div>
    <%!-- The navbar's Create new (J37): its button is the layout's. --%>
    <NewDocMenu.picker picks={NewDocMenu.picks(@desk.new)} />
    <%!-- The presence profile (the display name and colour others see):
          the navbar's own pill and the drawer's "Your profile" open it, with
          a document open or not. The hosted editor's shell leaves its own
          copy out (`EditorHost`), so there is one. --%>
    <BarkparkWeb.StudioComponents.profile_modal
      show_profile={@show_profile}
      user_name={@user_name}
      user_name_fallback={assigns[:user_name_fallback]}
      user_color={@user_color}
      account_label={assigns[:account_label]}
      account_path={account_path(assigns)}
      profile_error={assigns[:profile_error]}
    />
    <LiveRefresh.gone_notice gone={@desk_gone} panes={@desk_panes} chain={@chain} base={@base} />
    <%!-- `panes` is the TanStack Studio's name for this element. It is the
          page's main landmark until the Studio's editor, which brings its
          own, is hosted in it. The two labels are `bp-desk.js`'s: it names
          the strips and the dividers it draws, and fills in the title. --%>
    <div
      class="pane-layout panes dk"
      id="desk-panes"
      data-testid="panes"
      role={if is_nil(@active), do: "main"}
      data-focus-mode={@desk_focus != nil}
      data-desk-expand={gettext("Expand %{title}", title: "%{title}")}
      data-desk-resize={gettext("Resize pane")}
      data-desk-field-actions={BarkparkWeb.StaticAssets.path("bp-desk-field-actions.js")}
      data-desk-doc-clip={BarkparkWeb.StaticAssets.path("bp-desk-doc-clip.js")}
      data-desk-tags={BarkparkWeb.StaticAssets.path("bp-desk-tags.js")}
      data-desk-codelist={BarkparkWeb.StaticAssets.path("bp-desk-codelist.js")}
      data-desk-lang-tabs={BarkparkWeb.StaticAssets.path("bp-desk-lang-tabs.js")}
      data-desk-validation={BarkparkWeb.StaticAssets.path("bp-desk-validation.js")}
      data-desk-bulk={BarkparkWeb.StaticAssets.path("bp-desk-bulk.js")}
      data-desk-array-menu={BarkparkWeb.StaticAssets.path("bp-desk-array-menu.js")}
      data-desk-image={BarkparkWeb.StaticAssets.path("bp-desk-image.js")}
      data-desk-navbar={BarkparkWeb.StaticAssets.path("bp-desk-navbar.js")}
      data-desk-undo={BarkparkWeb.StaticAssets.path("bp-desk-undo.js")}
      data-desk-locked-value={BarkparkWeb.StaticAssets.path("bp-desk-locked-value.js")}
      data-desk-revision-focus={BarkparkWeb.StaticAssets.path("bp-desk-revision-focus.js")}
      data-desk-vision-js={BarkparkWeb.StaticAssets.path("bp-desk-vision.js")}
      data-desk-new-doc={BarkparkWeb.StaticAssets.path("bp-desk-new-doc.js")}
      data-desk-leave={BarkparkWeb.StaticAssets.path("bp-desk-leave.js")}
      style="flex: 1 1 auto; min-height: 0"
      phx-hook="Desk"
    >
      <%!-- The desk's Vision (`Desk.Vision`) in place of the panes. --%>
      <Vision.tool
        :if={@desk_tool == :vision}
        dataset={@dataset}
        datasets={@vision_datasets}
        scope_prefix={@scope_prefix}
      />
      <%!-- One loop, so the panes are in the page in chain order: the layout
            and the keys read that order. --%>
      <%= for view <- @desk_panes, @desk_tool != :vision do %>
      <%!-- The editor's section has an id of its own. On the pane's id the
            patch turned the pane into the editor in place, so the browser
            never let the pane's component go; a Back to that document then
            drew the component as an empty section until the editor came
            (row 5). --%>
      {if view.index == @active, do: EditorHost.pane(assigns, %{view | id: view.id <> "-editor"})}
      <.live_component
        :if={view.index != @active}
        module={PaneComponent}
        id={view.id}
        pane={view.pane}
        index={view.index}
        node={view.node}
        follows={view.follows}
        hint={view.title}
        hold={view.index == length(@desk_panes) - 1 and @pending != nil}
        warm={warm(@warm, view.key)}
        panes={@chain}
        base={@base}
        dataset={@dataset}
        scope={@scope}
        list_sort={ListMenu.kept(@list_sorts, @desk.menus, view.pane[:type])}
        orderings={menu(@desk, view).orderings}
        choices={@desk.new[view.pane[:type]] || []}
        sorts={menu(@desk, view).sorts}
        default={menu(@desk, view).default}
        focus={FocusMode.of(assigns, view)}
        bulk={Bulk.of(assigns, view.id)}
        bulk_confirm={@desk_bulk_confirm && @desk_bulk_confirm.pane == view.id && @desk_bulk_confirm}
        held={BarkparkWeb.Studio.StudioLive.PageTitle.held(assigns, view.pane[:type])}
      />
      <% end %>
    </div>
    </div>
    """
  end

  # The document open in the desk, for the Tasks sidebar's Active Document.
  defp active_doc_id(active, %{doc_id: id}) when is_integer(active) and is_binary(id),
    do: Barkpark.Content.published_id(id)

  defp active_doc_id(_active, _doc), do: nil

  # The tree is the same for every click in a dataset: build it once.
  defp desk(%{dataset: dataset} = desk, dataset, _scope), do: desk

  defp desk(_stale, dataset, scope) do
    root =
      dataset
      |> Structure.build([defer_group_by: true] ++ scope)
      |> StructureCopy.localize()
      |> root_title()
      |> Tree.normalize()

    # The list menus' sorts per type (`ListMenu`) and the types each type's
    # panes show through a reference (`LiveRefresh`), read with the tree: once.
    %{
      dataset: dataset,
      root: root,
      nodes: Tree.index(root),
      menus: ListMenu.menus(dataset, scope),
      new: NewDocMenu.all(dataset, scope),
      targets: LiveRefresh.targets(dataset, scope)
    }
  end

  defp menu(desk, view),
    do: desk.menus[view.pane[:type]] || %{orderings: [], sorts: [], default: "updated"}

  # The root's fallback title, when the desk document names none, is
  # Barkpark's word. Only the desk translates it: the old Studio makes its
  # pane's id from the title (`pane-structure`), so `StructureCopy` keeps it.
  # The TanStack Studio titles its root "Content" when no desk is declared
  # (a declared desk's own title otherwise); Barkpark.Structure's default is
  # "Structure". Two panes must not share a title (the strips, the headings
  # and the close links name them), so when a root row is itself titled
  # "Content" (Barkpark.Structure's content-types group) the root keeps
  # "Structure", in the viewer's language.
  @doc false
  def root_title(%{id: "root", title: "Structure"} = root) do
    content = gettext("Content")
    taken? = Enum.any?(root.items || [], &(Map.get(&1, :title) in [content, "Content"]))
    Map.put(root, :title, if(taken?, do: gettext("Structure"), else: content))
  end

  def root_title(root), do: root

  # A groupBy is built deferred, with no groups: the menu that opens it builds
  # them, as the Studio's own walk does (`Structure.expand/3`), and keeps them
  # for the visit, so its groups' lists find their nodes too.
  defp expand_open(desk, panes, dataset, scope) do
    Enum.reduce(panes, desk, fn
      %{missing: true}, desk ->
        desk

      %{kind: :menu, node: id}, desk ->
        case desk.nodes[id] do
          %{deferred: {:group_by, _item, _idx}} = node ->
            open =
              node
              |> Structure.expand(dataset, scope)
              |> StructureCopy.localize()
              |> Tree.normalize()

            %{desk | nodes: Map.merge(desk.nodes, Tree.index(open))}

          _ ->
            desk
        end

      _pane, desk ->
        desk
    end)
  end

  # The earlier pane that reads the same document (a split sibling's first):
  # the later one shows that read instead of making its own.
  defp leader(%{pane: %{kind: :doc}, key: key, index: index}, views),
    do: Enum.find_value(views, &((&1.key == key and &1.index < index) && &1.id))

  defp leader(_view, _views), do: nil
end
