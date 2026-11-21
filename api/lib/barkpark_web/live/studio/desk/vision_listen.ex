defmodule BarkparkWeb.Studio.Desk.VisionListen do
  @moduledoc """
  Vision's Listen on the desk (J37, TanStack's `vision-listen.ts`): the query's
  changes as they happen, until Stop. It runs over the desk's own LiveView
  socket, so no token is ever put in the page: the socket is already signed in
  and scoped to its workspace, project and dataset.

  The browser (`bp-desk-vision-listen.js`) sends `vision-listen-start` with
  what the query names, and `vision-listen-stop`. The server works out the
  rest from the socket alone:

    * The dataset must be the page's or one Vision lists for this caller, not
      greyed (`Desk.Vision.datasets/1`). A dataset-bound token may listen to
      its own dataset only.
    * The query only narrows. GROQ follows the types it names (`_type ==
      "post"`, `_type in [...]`), as TanStack's, and its filter runs on each
      document (`ListenFilter`'s `?query=`), with Params as `$name`. A GROQ
      query naming no type is refused with TanStack's words. The query-string
      form follows its type, its `perspective` and its `filter[field]=value`.
    * The workspace, project and a preview token's documents come from the
      socket's `scope_opts`, and a change is shown as this caller may see it
      (`VisionListenStream`).

  Each change goes to the page as the `desk-vision-listen` event (`kind:
  "mutation"`), with the listen stream's fields. The Listen ends on Stop, on a
  new Listen, when the page's dataset changes or Vision is left, and when the
  LiveView ends.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Auth.ApiToken
  alias BarkparkWeb.ListenFilter
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.VisionListenStream, as: Stream

  @event "desk-vision-listen"
  @type_name ~r/^[A-Za-z0-9_-]+$/
  # As the GROQ read's URL cap (docs/contracts/groq-query.md): a Listen never
  # takes more than the Fetch beside it could send.
  @max_bytes 32_753

  @doc "`vision-listen-start` and `vision-listen-stop`, from `DeskLive`."
  def handle_event("vision-listen-start", params, socket) do
    socket = stop(socket)
    id = listen_id(params)

    case socket.assigns[:desk_tool] == :vision && request(params, socket.assigns) do
      {:ok, dataset, filter} ->
        ref = make_ref()

        {:ok, pid} =
          Stream.start(self(), ref,
            dataset: dataset,
            scope: ScopeHelpers.scope_opts(socket),
            filter: filter
          )

        listening = %{pid: pid, ref: ref, id: id, page_dataset: socket.assigns.dataset}

        {:noreply,
         socket
         |> assign(:vision_listen, listening)
         |> push_event(@event, %{id: id, kind: "open"})}

      {:error, message} ->
        {:noreply, push_event(socket, @event, %{id: id, kind: "error", message: message})}

      false ->
        {:noreply, socket}
    end
  end

  def handle_event("vision-listen-stop", _params, socket), do: {:noreply, stop(socket)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @doc "A message from this socket's Listen; one from an ended Listen is dropped."
  def handle_info({:vision_listen, ref, message}, socket) do
    case socket.assigns[:vision_listen] do
      %{ref: ^ref, id: id} -> {:noreply, tell(socket, id, message)}
      _ -> {:noreply, socket}
    end
  end

  defp tell(socket, id, {:mutation, event}),
    do: push_event(socket, @event, %{id: id, kind: "mutation", event: event})

  defp tell(socket, id, {:skipped, n}),
    do: push_event(socket, @event, %{id: id, kind: "skipped", count: n})

  defp tell(socket, id, {:error, message}),
    do: socket |> ended() |> push_event(@event, %{id: id, kind: "error", message: message})

  defp tell(socket, id, :closed),
    do: socket |> ended() |> push_event(@event, %{id: id, kind: "closed"})

  @doc """
  After each `handle_params`: a Listen ends when Vision is left or the page's
  dataset changes. A page still on Vision is told, so its button reads Listen
  again.
  """
  def follow(socket) do
    case socket.assigns[:vision_listen] do
      %{page_dataset: ds, id: id} ->
        cond do
          socket.assigns[:desk_tool] != :vision ->
            stop(socket)

          socket.assigns.dataset != ds ->
            socket |> stop() |> push_event(@event, %{id: id, kind: "stopped"})

          true ->
            socket
        end

      _ ->
        socket
    end
  end

  @doc "End this socket's Listen, if any."
  def stop(socket) do
    case socket.assigns[:vision_listen] do
      %{pid: pid} ->
        Stream.stop(pid)
        ended(socket)

      _ ->
        socket
    end
  end

  defp ended(socket), do: assign(socket, :vision_listen, nil)

  defp listen_id(%{"id" => id}) when is_integer(id), do: id
  defp listen_id(_), do: 0

  @doc """
  What a `vision-listen-start` asks for, held to this page's scope:
  `{:ok, dataset, filter}` or `{:error, message}`.
  """
  def request(params, assigns) when is_map(params) do
    with {:ok, dataset} <- dataset(params["dataset"], assigns),
         {:ok, listen} <- listen_params(params),
         {:ok, filter} <- parse(listen) do
      scope = ScopeHelpers.scope_opts_from_assigns(assigns)

      filter =
        filter
        |> ListenFilter.narrow_to_project(Keyword.get(scope, :project_id))
        |> ListenFilter.narrow_to_only_doc_ids(Keyword.get(scope, :only_doc_ids))

      {:ok, dataset, filter}
    end
  end

  # The page's dataset, or one Vision lists for this caller and does not grey.
  # A dataset-bound token is held to its own, whatever the page is.
  defp dataset(ds, assigns) when is_binary(ds) do
    bound = ApiToken.bound_dataset(assigns[:api_token])

    listed? =
      ds == assigns[:dataset] or
        Enum.any?(assigns[:vision_datasets] || [], &(&1.slug == ds and not &1.off?))

    if listed? and (is_nil(bound) or bound == ds),
      do: {:ok, ds},
      else: {:error, gettext("Listen can only follow a dataset this page lists for you")}
  end

  defp dataset(_ds, _assigns),
    do: {:error, gettext("Listen can only follow a dataset this page lists for you")}

  # The query-string form: its type, and its query string's perspective and
  # equality filters, as TanStack's /api/vision-listen hands them on.
  defp listen_params(%{"type" => type, "qs" => qs}) when is_binary(type) and is_binary(qs) do
    with :ok <- small(type <> qs),
         true <- Regex.match?(@type_name, type) || {:error, refused()},
         {:ok, query} <- decode(qs) do
      {:ok, query |> Map.take(["perspective", "filter"]) |> Map.put("types", type)}
    end
  end

  # GROQ: the types it names, its perspective, the query and its Params.
  defp listen_params(%{"query" => query} = params) when is_binary(query) do
    given = if is_map(params["params"]), do: params["params"], else: %{}
    sent = Map.new(given, fn {key, value} -> {"$" <> to_string(key), Jason.encode!(value)} end)

    with :ok <- small(query <> Enum.join(Map.values(sent))) do
      case groq_types(query) do
        [] ->
          {:error, type_error()}

        types ->
          {:ok,
           sent
           |> Map.put("query", query)
           |> Map.put("types", Enum.join(types, ","))
           |> put_perspective(params["perspective"])}
      end
    end
  end

  defp listen_params(_params), do: {:error, gettext("Write a query to listen to")}

  defp put_perspective(listen, p) when is_binary(p), do: Map.put(listen, "perspective", p)
  defp put_perspective(listen, _p), do: listen

  defp type_error,
    do:
      gettext(
        ~s(Listen follows the document types a query names: add a _type filter, like _type == "post")
      )

  defp refused, do: gettext("The query cannot be listened to")

  defp small(text) do
    if byte_size(text) <= @max_bytes,
      do: :ok,
      else: {:error, gettext("The query is too long to send: its URL is over 32,753 bytes")}
  end

  defp decode(qs) do
    {:ok, Plug.Conn.Query.decode(qs)}
  rescue
    _ -> {:error, gettext("The query string could not be read")}
  end

  defp parse(listen) do
    case ListenFilter.parse(listen) do
      {:ok, filter} ->
        {:ok, filter}

      {:error, {:perspective, value}} ->
        {:error, gettext("Unknown perspective: %{value}", value: inspect(value))}

      {:error, {:filter, message, _details}} ->
        {:error, message}

      {:error, _} ->
        {:error, refused()}
    end
  end

  @doc """
  The types a GROQ query names, as TanStack's `groqTypes`: `_type == "x"` and
  `_type in ["x", "y"]`.
  """
  @spec groq_types(String.t()) :: [String.t()]
  def groq_types(query) when is_binary(query) do
    equal =
      Regex.scan(~r/_type\s*==\s*["']([A-Za-z0-9_.-]+)["']/, query, capture: :all_but_first)

    within =
      ~r/_type\s+in\s*\[([^\]]*)\]/
      |> Regex.scan(query, capture: :all_but_first)
      |> Enum.flat_map(fn [list] ->
        Regex.scan(~r/["']([A-Za-z0-9_.-]+)["']/, list, capture: :all_but_first)
      end)

    (equal ++ within) |> List.flatten() |> Enum.uniq()
  end
end
