defmodule BarkparkWeb.Studio.AuditLive do
  @moduledoc """
  Studio Activity page: the workspace's audit log, for its admins.

  An admin sees who did what and when: content changes, token mints and
  revocations, access grants, seat changes and webhook changes. They filter by
  category, by actor (type an id, or click a name in the list) and by dates,
  and page back with "Load more".

  ## Scope and access

  Every row comes from `Barkpark.Audit.Feed.list/3`, the same read as
  `GET /w/:ws/p/:proj/v1/audit`, for the workspace and project in the URL
  (`LiveScope` resolves them for the `:scoped_studio` session). So the page
  shows rows of this project and workspace-level rows with no project, and
  never another project's, another workspace's or an instance-level row.
  Without a resolved workspace and project the page refuses rather than read.

  Admin is the workspace seat (`Studio.Caps.admin?/1`), asked at mount, on
  every URL change and on every event, as on the Search and Webhooks pages.
  A demoted admin is sent away on their next click.

  Filters live in the URL query (`category`, `actor`, `since`, `until`), so a
  filtered view can be shared with another admin. The paging position stays
  on the server: the browser never sees an event id.
  """

  use BarkparkWeb, :live_view

  require Logger

  import BarkparkWeb.Studio.PageScroll

  alias Barkpark.Audit.Feed
  alias BarkparkWeb.Studio.AuditLive.View
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.Desk.Text

  on_mount {BarkparkWeb.WriteAdmissionLive, :refuse_while_held}

  @filter_keys ~w(category actor since until)

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    # A dataset segment the database refuses as text names no dataset: a 404
    # before the first read, as on the Search and Webhooks pages.
    Text.text?(dataset) || raise BarkparkWeb.Studio.DeskLive.NotFound

    if admin?(socket) do
      {:ok,
       socket
       |> assign_new(:scope_prefix, fn -> "" end)
       |> assign(
         dataset: dataset,
         page_title: gettext("Activity"),
         path: nil,
         filters: %{},
         events: [],
         next: nil,
         error: nil
       )}
    else
      {:ok, refuse(socket)}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    dataset = params["dataset"]

    cond do
      not admin?(socket) ->
        {:noreply, refuse(socket)}

      not (is_binary(dataset) and Text.text?(dataset)) ->
        {:noreply, refuse(socket)}

      true ->
        filters = filters_from(params)

        {:noreply,
         socket
         |> assign(dataset: dataset, path: URI.parse(uri).path, filters: filters)
         |> load_first()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.studio_page_scroll>
      <View.page
        filters={@filters}
        events={@events}
        more?={not is_nil(@next)}
        error={@error}
      />
    </.studio_page_scroll>
    """
  end

  # Every event asks for admin again: a phx event can come from a socket whose
  # seat changed after mount, or from markup that was never rendered.
  @impl true
  def handle_event(event, params, socket) when event in ~w(filter clear actor more) do
    if admin?(socket),
      do: {:noreply, event(event, params, socket)},
      else: {:noreply, refuse(socket)}
  end

  # Fall-through: a stale or forged phx event must not crash the session.
  def handle_event(event, _params, socket) do
    Logger.warning("studio/activity: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  defp event("filter", %{"filter" => %{} = f}, socket), do: patch(socket, filters_from(f))
  defp event("clear", _params, socket), do: patch(socket, %{})

  defp event("actor", %{"id" => id}, socket) when is_binary(id),
    do: patch(socket, Map.put(socket.assigns.filters, "actor", id))

  defp event("more", _params, %{assigns: %{next: next}} = socket) when is_integer(next) do
    case page(socket, next) do
      {:ok, page} -> assign(socket, events: socket.assigns.events ++ page.events, next: page.next)
      {:error, message} -> assign(socket, error: message)
    end
  end

  # A known event with params of another shape: nothing to do.
  defp event(_event, _params, socket), do: socket

  # The filters go into the URL; `handle_params/3` reads them back, asks for
  # admin again and loads the first page.
  defp patch(socket, filters) do
    query = if filters == %{}, do: "", else: "?" <> URI.encode_query(filters)
    push_patch(socket, to: (socket.assigns.path || "") <> query)
  end

  defp load_first(socket) do
    case page(socket, nil) do
      {:ok, page} -> assign(socket, events: page.events, next: page.next, error: nil)
      {:error, message} -> assign(socket, events: [], next: nil, error: message)
    end
  end

  defp page(socket, before_id) do
    case Feed.parse(socket.assigns.filters) do
      {:ok, filters} ->
        filters = if before_id, do: Map.put(filters, :before_id, before_id), else: filters

        %{events: events, next_before_id: next} =
          Feed.list(
            socket.assigns.current_workspace.id,
            socket.assigns.current_project.id,
            filters
          )

        {:ok, %{events: events, next: next}}

      {:error, {:invalid, field}} ->
        {:error, View.invalid_message(field)}
    end
  end

  # Only the four filter keys, only as text, blanks dropped.
  defp filters_from(params) do
    for key <- @filter_keys,
        value = params[key],
        is_binary(value) and Text.text?(value),
        trimmed = String.trim(value),
        trimmed != "",
        into: %{},
        do: {key, trimmed}
  end

  # The workspace seat, asked live, and only for a workspace and project the
  # URL resolved. Without both the feed has no scope to read, so the page
  # refuses instead.
  defp admin?(socket) do
    is_binary(id_of(socket.assigns[:current_workspace])) and
      is_binary(id_of(socket.assigns[:current_project])) and unbound_admin?(socket)
  end

  defp id_of(%{id: id}), do: id
  defp id_of(_), do: nil

  # The refusal the other admin pages give.
  defp refuse(socket) do
    socket
    |> put_flash(:error, gettext("Admin access required"))
    |> redirect(to: "/studio")
  end

  # The admin seat, held by a session whose token is not bound to a dataset:
  # the feed answers for the whole workspace, which a bound token may not read
  # (`BarkparkWeb.Plugs.RefuseDatasetBound`, the same rule as `GET …/v1/audit`).
  # Kept last so the gettext references above keep their lines.
  defp unbound_admin?(socket) do
    Caps.admin?(socket) and
      not BarkparkWeb.Plugs.RefuseDatasetBound.refused?(socket.assigns[:api_token])
  end
end
