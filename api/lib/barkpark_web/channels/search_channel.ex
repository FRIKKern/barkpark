defmodule BarkparkWeb.SearchChannel do
  @moduledoc """
  Per-keystroke live search over one persistent WebSocket. The browser opens a
  channel `"search:<ws>:<proj>:<dataset>"` and pushes a `"query"` frame on every
  keystroke; we reply with the same response shape `SearchController.search/2`
  serves — so the client renders identically whether the hit came over HTTP or
  the socket. The win is purely transport: no per-keystroke TLS handshake, no
  Vercel hop, just a frame on an already-open connection.

  ## Scope + auth (the P0 leak guard)

  The topic names the tenant scope by slug. On join we resolve the workspace +
  project the SAME way the HTTP plugs do (`Tenancy.get_workspace_by_slug/1` +
  `Tenancy.get_project/2`) and authorize the socket's token against the
  workspace (`Tenancy.Auth.authorize/3`, `:read`). The resolved structs land in
  `current_workspace` / `current_project` so `ScopeHelpers.scope_opts/1` (which
  already pattern-matches `%Phoenix.Socket{}`) threads the exact same
  `workspace_id` / `dataset` filter every other read path uses. A token that
  isn't authorized for the workspace fails the join closed — it never reaches
  `handle_in`.

  ## Stale-reply ordering

  Each `"query"` frame carries a client `seq`; we echo it back untouched. Phoenix
  already matches a reply to its push by ref, but the `seq` lets the client drop
  a reply whose query has since been superseded by later typing without tracking
  refs itself.
  """
  use Phoenix.Channel

  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Content.Envelope

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @max_limit 100

  @impl true
  def join("search:" <> scope, _params, socket) do
    with [ws_slug, proj_slug, dataset] <- String.split(scope, ":"),
         %Tenancy.Workspace{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         :ok <- TenancyAuth.authorize(socket.assigns.api_token, ws.id, :read),
         %Tenancy.Project{} = proj <- Tenancy.get_project(ws_slug, proj_slug) do
      socket =
        socket
        |> assign(:current_workspace, ws)
        |> assign(:current_project, proj)
        |> assign(:dataset, dataset)

      {:ok, socket}
    else
      [_ | _] -> {:error, %{reason: "bad_topic"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("query", %{"q" => q} = params, socket) do
    seq = params["seq"]

    case String.trim(to_string(q)) do
      "" ->
        {:reply, {:ok, empty_reply(seq, "")}, socket}

      query ->
        opts =
          [
            type: params["type"],
            types: parse_types(params["types"]),
            perspective: :published,
            limit: clamp_limit(params["limit"]),
            offset: parse_int(params["offset"], 0),
            engine: params["engine"] || "indx"
          ] ++ scope_opts(socket)

        {docs, count, meta} = Content.search_documents(query, socket.assigns.dataset, opts)

        reply = %{
          seq: seq,
          documents: Envelope.render_many(docs),
          count: count,
          query: query,
          parsedQuery: meta[:parsed],
          highlights: meta[:highlights] || %{},
          recovery: meta[:recovery],
          correctedTo: meta[:corrected_to],
          facets: meta[:facets],
          truncation: meta[:truncation]
        }

        {:reply, {:ok, reply}, socket}
    end
  end

  defp empty_reply(seq, query) do
    %{
      seq: seq,
      documents: [],
      count: 0,
      query: query,
      parsedQuery: nil,
      highlights: %{},
      recovery: nil,
      correctedTo: nil,
      facets: nil,
      truncation: nil
    }
  end

  # `types` arrives as a comma-joined string ("post,page") or a JSON array;
  # normalise to a non-empty list of trimmed strings, or nil to mean "defaults".
  defp parse_types(nil), do: nil
  defp parse_types(list) when is_list(list), do: present_list(list)

  defp parse_types(str) when is_binary(str) do
    str |> String.split(",") |> present_list()
  end

  defp parse_types(_), do: nil

  defp present_list(list) do
    case list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      l -> l
    end
  end

  defp clamp_limit(v) do
    v |> parse_int(50) |> max(1) |> min(@max_limit)
  end

  defp parse_int(n, _default) when is_integer(n), do: n

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
