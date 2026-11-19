defmodule BarkparkWeb.PaperAnswerSweep.Introspect do
  @moduledoc """
  What the answer sweep drives, read from the compiled application, never
  from a list typed by hand:

    * every route of `BarkparkWeb.Router.__routes__/0`, live routes included;
    * every channel each endpoint socket routes to, with the events its
      `handle_in/3` matches, from the socket's and channel's debug info;
    * whether a route is read-shaped: whether its action, or any function of
      its own module the action reaches, names `Envelope` or answers with
      documents (`returnDocuments`, a `documents`/`document` key), read from
      the controller's debug info. A read-shaped route must be driven to an
      answer the caller with the right is given in full.
  """

  alias BarkparkWeb.Router

  @doc "Every route, once per verb and path."
  def routes do
    Router.__routes__()
    |> Enum.map(fn r ->
      %{
        verb: r.verb |> Atom.to_string() |> String.upcase(),
        path: r.path,
        plug: r.plug,
        action: r.plug_opts,
        live: live_view(r)
      }
    end)
    |> Enum.uniq_by(&{&1.verb, &1.path})
  end

  defp live_view(%{metadata: %{phoenix_live_view: {module, _, _, _}}}), do: module
  defp live_view(%{metadata: %{phoenix_live_view: {module, _, _}}}), do: module
  defp live_view(_route), do: nil

  @doc "Whether `route` can answer with document content (see moduledoc)."
  def read_shaped?(%{live: live}) when live != nil, do: true
  def read_shaped?(%{verb: "GET"}), do: true

  def read_shaped?(%{plug: plug, action: action}) when is_atom(action) do
    case definitions(plug) do
      nil -> true
      defs -> reaches_documents?(defs, [{action, 2}], MapSet.new())
    end
  end

  def read_shaped?(_route), do: true

  @document_markers ["returnDocuments", "return_documents", :documents, :document, "documents"]

  defp reaches_documents?(_defs, [], _seen), do: false

  defp reaches_documents?(defs, [fun | rest], seen) do
    if MapSet.member?(seen, fun) do
      reaches_documents?(defs, rest, seen)
    else
      clauses = Map.get(defs, fun, [])
      {hit, calls} = scan(clauses, Map.keys(defs))
      hit or reaches_documents?(defs, calls ++ rest, MapSet.put(seen, fun))
    end
  end

  # Whether the AST names `Envelope` or a document marker, and which of the
  # module's own functions it calls.
  defp scan(ast, local_funs) do
    local = MapSet.new(local_funs)

    {_, acc} =
      Macro.prewalk(ast, {false, []}, fn
        Barkpark.Content.Envelope = node, {_, calls} ->
          {node, {true, calls}}

        node, {hit, calls} when node in @document_markers ->
          {node, {hit or true, calls}}

        {name, _, args} = node, {hit, calls} when is_atom(name) and is_list(args) ->
          fun = {name, length(args)}
          {node, {hit, if(MapSet.member?(local, fun), do: [fun | calls], else: calls)}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  @doc "`%{{name, arity} => clauses}` from `module`'s debug info, or nil."
  def definitions(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(path, [:debug_info]),
         {:ok, %{definitions: defs}} <- backend.debug_info(:elixir_v1, module, data, []) do
      Map.new(defs, fn {fun, _kind, _meta, clauses} -> {fun, clauses} end)
    else
      _ -> nil
    end
  end

  defp defs(module), do: definitions(module) || %{}

  @doc """
  `[{socket_path, socket_module, topic_prefix, channel_module, events}]` for
  every channel route of every endpoint socket (LiveView's own excepted: its
  routes are the live routes).
  """
  def channels(endpoint) do
    for {path, socket, _opts} <- endpoint.__sockets__(),
        socket != Phoenix.LiveView.Socket,
        {prefix, channel} <- channel_routes(socket),
        do: {path, socket, prefix, channel, events(channel)}
  end

  defp channel_routes(socket) do
    socket
    |> defs()
    |> Map.get({:__channel__, 1}, [])
    |> Enum.flat_map(fn {_meta, [topic], _guards, body} ->
      case {prefix(topic), channel_module(body)} do
        {prefix, module} when is_binary(prefix) and is_atom(module) and module != nil ->
          [{prefix, module}]

        _ ->
          []
      end
    end)
  end

  defp prefix(topic) when is_binary(topic), do: topic
  defp prefix({:<>, _, [prefix, _]}) when is_binary(prefix), do: prefix
  defp prefix(_), do: nil

  defp channel_module(body) do
    {_, found} =
      Macro.prewalk(body, nil, fn
        module, nil when is_atom(module) and module not in [nil, true, false] ->
          {module, if(channel?(module), do: module)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp channel?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :join, 3)
  end

  defp events(channel) do
    channel
    |> defs()
    |> Map.get({:handle_in, 3}, [])
    |> Enum.flat_map(fn
      {_meta, [event | _], _guards, _body} when is_binary(event) -> [event]
      _ -> []
    end)
    |> Enum.uniq()
  end
end
