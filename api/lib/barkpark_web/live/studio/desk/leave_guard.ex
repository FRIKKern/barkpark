defmodule BarkparkWeb.Studio.Desk.LeaveGuard do
  @moduledoc """
  What the desk asks before it leaves a document with a held field
  (task-33cbb6269c8823ad): typing whose save did not land (refused, or held
  over another editor's rewrite, `editor_unsaved_keys`), or a field the
  store refused (`RefusedSave`).

  The question is the desk's own dialog (`dialog/1`), asked by the server
  before anything leaves:

    * a link (a row, a breadcrumb, a pane's ×, the navbar):
      `bp-desk-leave.js` holds the click back and sends it (`desk-leave`), so the URL has not
      moved. A desk link that keeps the document goes on at once; the
      dialog's Leave on a link that leaves the page is that link;
    * Enter on a search hit (`desk-search-open`) and Create new
      (`new-document`), before anything moves or is made;
    * any other patch that puts the document away, Back above all:
      `DeskLive.handle_params/3` keeps the document and asks, the URL already
      moved; Stay patches it back to the document.

  The edit pane carries the question as `data-desk-held`, so the tab's close
  or reload asks too, as the TanStack Studio's `beforeunload` does over
  `hasUnsaved()` (`lib/edits.ts`). Leaving drops the held text: the next
  document's form replaces it. Nothing held, nothing asked.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.DocDialog
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.Text
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StudioLive.RefusedSave

  @doc "Whether leaving the open document now asks: a field is held, and Leave was not just pressed."
  def ask?(socket), do: doc(socket.assigns) != nil and socket.assigns[:desk_leave_pass] != true

  @doc """
  Whether the desk URL `params` name keeps the open document in the editor,
  as `EditorHost.follow/3` keeps it: the same dataset and the same document
  in the last pane. Vision and any other dataset put it away.
  """
  def keeps?(socket, params) do
    %{dataset: dataset, desk: desk} = socket.assigns
    splat = params |> Map.get("panes", []) |> Enum.join("/") |> Text.text_only()

    (params["dataset"] || dataset) == dataset and params["panes"] != ["_tools", "vision"] and
      EditorHost.target(Tree.parse(splat, desk.root), dataset) == socket.assigns[:editing]
  end

  @doc """
  Whether a desk path keeps the open document (`keeps?/2`, its params read
  as the router reads a patch's). A path that is not the desk's never does.
  """
  def keeps_path?(socket, path) do
    case Phoenix.Router.route_info(BarkparkWeb.Router, "GET", URI.parse(path).path || "", nil) do
      %{phoenix_live_view: {BarkparkWeb.Studio.DeskLive, _, _, _}, path_params: params} ->
        keeps?(socket, params)

      _ ->
        false
    end
  end

  @doc """
  Open the dialog for `to`: `{:patch, params, uri}` (the URL already moved),
  `{:event, name, params}` (replayed on Leave) or `{:link, href, kind}` (a
  link that leaves the page: `:redirect`, a live one, or `:page`). `back` is
  where the document is open.
  """
  def ask(socket, to) do
    back = URI.parse(socket.assigns.desk_uri)
    back = if back.query, do: back.path <> "?" <> back.query, else: back.path
    Phoenix.Component.assign(socket, :desk_leave, %{to: to, back: back})
  end

  @doc """
  After each render: a question still open over a hold that has ended (a
  save landed, the draft was discarded) is closed as Stay closes it
  (`DeskLive.handle_info/2`), so it never stands empty.
  """
  def follow(socket) do
    if socket.assigns[:desk_leave] && is_nil(doc(socket.assigns)),
      do: send(self(), :desk_leave_cleared)

    socket
  end

  @doc """
  After a Studio event: Delete and Duplicate patch away from the document
  once they are done; that patch passes the guard, as nothing is left to
  keep.
  """
  def done({:noreply, socket}, event) when event in ~w(confirm-delete duplicate-doc),
    do: {:noreply, pass(socket)}

  def done({:reply, reply, socket}, event) when event in ~w(confirm-delete duplicate-doc),
    do: {:reply, reply, pass(socket)}

  def done(result, _event), do: result

  defp pass(%{redirected: {:live, :patch, _}} = socket),
    do: Phoenix.Component.assign(socket, :desk_leave_pass, true)

  defp pass(socket), do: socket

  @doc """
  A link `bp-desk-leave.js` may hand over: a path on this site. No space,
  control byte or backslash anywhere: a browser drops a tab or newline from
  a URL, so "/<TAB>/evil.example" is read as "//evil.example", another site
  (task-bbe2d34a97db65c9). The script hands over a parsed path, which has
  none of them.
  """
  def local?(href),
    do:
      is_binary(href) and String.starts_with?(href, "/") and not String.starts_with?(href, "//") and
        not Regex.match?(~r/[\x00-\x20\x7f\\]/, href)

  attr :id, :string, required: true
  attr :leave, :map, required: true, doc: "`desk_leave`: `%{to:, back:}`"
  attr :message, :string, default: nil, doc: "`message/1`"

  @doc "The question, open. Stay, Escape and the backdrop stay; Leave goes."
  def dialog(assigns) do
    ~H"""
    <DocDialog.frame id={@id} name="leave" title={gettext("Leave this document?")} close="desk-leave-stay">
      <p>{@message}</p>
      <:actions>
        <button type="button" class="dk-dialog-btn btn" phx-click="desk-leave-stay" data-modal-focus>
          {gettext("Stay")}
        </button>
        <.link
          :if={match?({:link, _, :redirect}, @leave.to)}
          navigate={elem(@leave.to, 1)}
          class="dk-dialog-btn btn danger"
          data-desk-leave-go
        >
          {gettext("Leave")}
        </.link>
        <a
          :if={match?({:link, _, :page}, @leave.to)}
          href={elem(@leave.to, 1)}
          class="dk-dialog-btn btn danger"
          data-desk-leave-go
        >
          {gettext("Leave")}
        </a>
        <button
          :if={not match?({:link, _, _}, @leave.to)}
          type="button"
          class="dk-dialog-btn btn danger"
          phx-click="desk-leave-go"
          data-desk-leave-go
        >
          {gettext("Leave")}
        </button>
      </:actions>
    </DocDialog.frame>
    """
  end

  @doc "The question, naming the held fields; nil when nothing is held."
  @spec message(map()) :: String.t() | nil
  def message(assigns) do
    case keys(assigns) do
      [] ->
        nil

      keys ->
        gettext(
          "Not saved: %{fields}. What you typed there will be lost.",
          fields: Enum.map_join(keys, ", ", &title(assigns, &1))
        )
    end
  end

  @doc "The open document's published id while a field is held, else nil."
  @spec doc(map()) :: String.t() | nil
  def doc(assigns) do
    with [_ | _] <- keys(assigns),
         %{doc_id: id} when is_binary(id) <- assigns[:editor_doc] do
      Barkpark.Content.published_id(id)
    else
      _ -> nil
    end
  end

  # The held top-level fields, in the schema's order.
  defp keys(assigns) do
    held =
      (assigns[:editor_unsaved_keys] || MapSet.new())
      |> MapSet.union(MapSet.new(refused(assigns)))

    order = Enum.map(fields(assigns), &(is_map(&1) && &1["name"]))
    Enum.sort_by(held, &(Enum.find_index(order, fn name -> name == &1 end) || length(order)))
  end

  defp refused(%{editor_doc: _} = assigns), do: RefusedSave.keys(assigns)
  defp refused(_assigns), do: []

  defp title(assigns, key) do
    case Enum.find(fields(assigns), &(is_map(&1) and &1["name"] == key)) do
      %{"title" => title} when is_binary(title) and title != "" -> title
      _ -> key
    end
  end

  defp fields(assigns) do
    case assigns[:editor_schema] do
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end
  end
end
