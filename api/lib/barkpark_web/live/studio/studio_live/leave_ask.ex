defmodule BarkparkWeb.Studio.StudioLive.LeaveAsk do
  @moduledoc """
  Studio asks on the server before it leaves a document with a held field
  (task-c4b59891f88686e0, task-5b4914f1b5f21594), with the desk's dialog
  (`Desk.LeaveGuard.dialog/1`), naming the field (`LeaveGuard.message/1`).

    * a press: a list row, a crumb, New document (`phx-click` buttons, which
      bp-studio-leave.js never sees). It stays where it is and asks; Leave
      makes the press. A press on the open document's own row asks too: it
      opens the document again from the store, and the held words go;
    * a link (bp-studio-leave.js): while a field is held, a plain click on
      a link to another place on this site is held back before the URL
      moves and handed to the server through the bridge button
      (`bridge/1`, `studio-leave`), which goes on at once (nothing held by
      then) or asks. Leave on a link that leaves the page is that link
      (`data-desk-leave-go`, so the tab's `beforeunload` does not ask too);
      a patch link is made again past the guard;
    * any patch to another place, Back above all. LiveView turns Back into
      `handle_params/3`, the URL already moved: the document stays and the
      dialog asks; Leave goes on with that patch, Stay patches the URL back.

  Studio reads the document again from the store on every patch, even one
  to the same document (`Lifecycle.finish_handle_params/6`), so Stay's patch
  back would drop the words it kept. Stay marks that one return: the next
  patch, if it is to the same place, does nothing. The mark goes with that
  next patch, whatever it is, so it never holds back any other.

  Nothing held, nothing asked. A patch that keeps the place (a query only)
  goes on as before. On the desk, which drives Studio's handlers for its
  editor (`Desk.EditorHost`), nothing here acts: the desk asks for itself
  (`Desk.LeaveGuard`).
  """

  use Phoenix.Component
  import Phoenix.LiveView, only: [push_patch: 2]

  alias BarkparkWeb.Studio.Desk.LeaveGuard

  @doc "No question open."
  def init(socket),
    do:
      assign(socket,
        studio_leave: nil,
        studio_leave_pass: false,
        studio_leave_return: nil,
        studio_leave_uri: nil
      )

  @doc """
  After each render: a question still open over a hold that has ended (a
  save landed) is closed as Stay closes it (`:studio_leave_cleared`), so it
  never stands empty.
  """
  def follow(socket) do
    if (not desk?(socket) and socket.assigns[:studio_leave]) && not held?(socket),
      do: send(self(), :studio_leave_cleared)

    socket
  end

  @doc "Whether the hold that asked has ended (for `:studio_leave_cleared`)."
  def cleared?(socket), do: socket.assigns[:studio_leave] != nil and not held?(socket)

  @doc "A press: `{:go, socket}`, or `{:stay, socket}` with the question open."
  def ask(event, params, socket) do
    if not desk?(socket) and held?(socket),
      do: {:stay, open(socket, {:event, event, params})},
      else: {:go, socket}
  end

  @doc """
  Before a patch is read (`place` is `{dataset, path, desk}`, as the patch
  names it): `{:route, socket}` reads it, `{:stop, socket}` keeps the
  document, with the question open, or as Stay's own return.
  """
  def params(socket, params, uri, place) do
    if desk?(socket), do: {:route, socket}, else: studio_params(socket, params, uri, place)
  end

  defp studio_params(socket, params, uri, place) do
    return = socket.assigns[:studio_leave_return]
    socket = assign(socket, :studio_leave_return, nil)

    cond do
      return != nil and return == place ->
        {:stop, socket}

      # Forward (or any patch) back to the held document while the question
      # is open: Stay, with the URL already there. Reading it would draw the
      # stored document over what is held (task-eac6c59213877806).
      socket.assigns[:studio_leave] != nil and place == here(socket) ->
        {:stop, assign(socket, :studio_leave, nil)}

      socket.assigns[:studio_leave_pass] != true and held?(socket) and place != here(socket) ->
        {:stop, open(socket, {:patch, params, uri})}

      true ->
        {:route,
         assign(socket, studio_leave: nil, studio_leave_pass: false, studio_leave_uri: back(uri))}
    end
  end

  @doc """
  A link bp-studio-leave.js held back (`studio-leave`, `href` and its
  LiveView `kind`: "patch", "redirect", or "" for a page load):
  `{:go, socket}` with the way there, or the question open. A path that is
  not this site's goes nowhere.
  """
  def link(%{"href" => href} = params, socket) do
    local? = LeaveGuard.local?(href)
    kind = if local?, do: LeaveGuard.kind(socket, href, params["kind"]), else: params["kind"]
    params = Map.put(params, "kind", kind)

    cond do
      not local? ->
        {:stay, socket}

      not desk?(socket) and held?(socket) and socket.assigns[:studio_leave_pass] != true ->
        to =
          case kind do
            "patch" -> {:event, "studio-leave", params}
            "redirect" -> {:link, href, :redirect}
            _ -> {:link, href, :page}
          end

        {:stay, open(socket, to)}

      kind == "patch" ->
        {:go, push_patch(socket, to: href)}

      kind == "redirect" ->
        {:go, Phoenix.LiveView.push_navigate(socket, to: href)}

      true ->
        {:go, Phoenix.LiveView.redirect(socket, to: href)}
    end
  end

  def link(_params, socket), do: {:stay, socket}

  @doc "Stay: the question closes; a patch it asked about is patched back."
  def stay(socket) do
    socket =
      case socket.assigns[:studio_leave] do
        %{to: {:patch, _, _}, back: back} when is_binary(back) ->
          socket
          |> assign(:studio_leave_return, here(socket))
          |> push_patch(to: back)

        _ ->
          socket
      end

    assign(socket, :studio_leave, nil)
  end

  @doc "Leave: what was asked, `{:patch, params, uri}`, `{:event, event, params}` or nil, past the guard once."
  def go(socket) do
    to = socket.assigns[:studio_leave] && socket.assigns.studio_leave.to
    {to, assign(socket, studio_leave: nil, studio_leave_pass: true)}
  end

  @doc """
  A press asked about, run again through every `handle_event` hook the
  socket has, in order: the list the press passed when it was made. `{:cont,
  socket}`, or `{:halt, socket}` from the first hook that refuses it.

  This is LiveView 1.1's own reducer, `Phoenix.LiveView.Lifecycle.handle_event/3`,
  which is private to LiveView (`@moduledoc false`). An upgrade that renames
  or reshapes it reds `studio_leave_regate_test.exs`'s "revoked under the question"
  tests, rather than letting a stored press skip the gates.
  """
  def hooks(event, params, socket) do
    case Phoenix.LiveView.Lifecycle.handle_event(event, params, socket) do
      {:cont, socket} -> {:cont, socket}
      {:halt, socket} -> {:halt, socket}
      {:halt, _reply, socket} -> {:halt, socket}
    end
  end

  attr :a, :map, required: true, doc: "the Studio's assigns"

  @doc "The bridge, and the question when one is open, drawn from the Studio's assigns."
  def asked(assigns) do
    ~H"""
    <.bridge />
    <.dialog
      :if={@a[:studio_leave]}
      leave={@a.studio_leave}
      message={BarkparkWeb.Studio.Desk.LeaveGuard.message(@a)}
    />
    """
  end

  @doc "After Leave's press: the pass is for the patch it sent; with none, it ends here."
  def passed(%{redirected: {:live, :patch, _}} = socket), do: socket
  def passed(socket), do: assign(socket, :studio_leave_pass, false)

  @doc """
  The button bp-studio-leave.js hands a held-back link to: it sets
  `phx-value-href` and `phx-value-kind` and clicks it, so the link reaches
  the server with no hook.
  """
  def bridge(assigns) do
    ~H"""
    <button id="studio-leave-ask" type="button" phx-click="studio-leave" hidden aria-hidden="true" tabindex="-1"></button>
    """
  end

  attr :leave, :map, required: true
  attr :message, :string, default: nil

  @doc """
  The desk's question, in Studio's look: the frame's own stylesheet is the
  desk's (`.dk`, its tokens), so Studio draws it with its modal's
  (`.modal-backdrop`, `.modal-card` in root.html.heex). Where it sits (fixed,
  centred) is the frame's sheet, for `.studio-leave` as for `.dk`.
  """
  def dialog(assigns) do
    ~H"""
    <div class="studio-leave">
      <style>
        .studio-leave .dk-dialog-backdrop { z-index: 51; background: hsl(var(--bp-scrim-hsl) / 0.45); }
        .studio-leave .dk-dialog { z-index: 52; margin: 0; padding: 0; border: 1px solid var(--border); border-radius: var(--radius-lg); background: var(--bg-card); color: var(--fg); box-shadow: 0 16px 48px hsl(var(--bp-shadow-hsl) / 0.25); }
        .studio-leave .dk-dialog-head { display: flex; align-items: center; gap: 8px; padding: 16px 16px 0 20px; }
        .studio-leave .dk-dialog-head h2 { flex: 1 1 auto; min-width: 0; margin: 0; font-size: var(--text-base); font-weight: 600; }
        .studio-leave .dk-dialog-close { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--fg-muted); cursor: pointer; }
        .studio-leave .dk-dialog-close:hover { color: var(--fg); }
        .studio-leave .dk-dialog-body { padding: 12px 20px 4px; overflow: auto; }
        .studio-leave .dk-dialog-body p { margin: 0 0 12px; overflow-wrap: anywhere; }
        .studio-leave .dk-dialog-foot { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 8px; padding: 12px 20px 16px; }
        .studio-leave .dk-dialog-btn.danger { background: var(--destructive); border-color: var(--destructive); color: var(--bg-card); }
        .studio-leave .dk-dialog-btn:focus-visible, .studio-leave .dk-dialog-close:focus-visible { outline: 2px solid var(--ring); outline-offset: 2px; }
      </style>
      <LeaveGuard.dialog id="studio-leave-dialog" leave={@leave} message={@message} />
    </div>
    """
  end

  defp open(socket, to) do
    back = socket.assigns[:studio_leave_uri]
    assign(socket, :studio_leave, %{to: to, back: back})
  end

  defp desk?(socket), do: is_binary(socket.assigns[:desk_base])

  defp held?(socket), do: not is_nil(LeaveGuard.doc(socket.assigns))

  defp here(socket),
    do: {socket.assigns[:dataset], socket.assigns[:nav_path] || [], socket.assigns[:nav_desk]}

  defp back(uri) when is_binary(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    if query, do: path <> "?" <> query, else: path
  end

  defp back(_uri), do: nil
end
