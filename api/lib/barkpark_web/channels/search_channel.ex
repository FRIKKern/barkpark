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
  `handle_in`. The dataset leaf is validated the same way (`get_dataset/2`,
  scoped to the resolved project) and refused with `"unknown_dataset"`: a topic
  naming a dataset that does not exist used to join green and return count=0
  forever, which reads as "the search is broken" instead of "your topic is
  wrong".

  The `perspective` is PINNED to `:published` in `handle_in` and is never read
  from the client frame — a socket holding a read token must not be able to
  ask for drafts. `search_channel_test.exs` guards that with a regression test.

  ## Stale-reply ordering

  Each `"query"` frame carries a client `seq`; we echo it back untouched. Phoenix
  already matches a reply to its push by ref, but the `seq` lets the client drop
  a reply whose query has since been superseded by later typing without tracking
  refs itself.

  ## Live push on document mutation (P5)

  After every `"query"` frame the channel caches the last-seen parameters in
  socket assigns (`:last_query`). On join we subscribe to the workspace-scoped
  PubSub topic the `Content.Broadcast` taps publish to
  (`documents:ws:<ws_id>:<dataset>`, falling back to the global
  `documents:<dataset>` topic when no workspace was resolved). When a
  `{:document_changed, _msg}` arrives, the channel re-runs the cached query
  against the latest state and pushes the result as a `"results"` event with the
  SAME payload shape the `"query"` reply uses — so the client renders live
  updates through the same shaper it already uses for replies, without polling.
  Channels with no cached query (e.g. an empty `""` or no query yet) get a
  no-op; the channel only wakes for queries the user is actively running.
  """
  use Phoenix.Channel

  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Content.CallerContext
  alias Barkpark.Search.HitEnvelope

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @max_limit 100

  @impl true
  def join("search:" <> scope, _params, socket) do
    with [ws_slug, proj_slug, dataset] <- String.split(scope, ":"),
         %Tenancy.Workspace{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         :ok <- TenancyAuth.authorize(socket.assigns.api_token, ws.id, :read),
         %Tenancy.Project{} = proj <- Tenancy.get_project(ws_slug, proj_slug),
         # The dataset leaf of the topic used to be trusted as a free string:
         # an unknown dataset joined GREEN and then matched zero rows forever,
         # because the read path degrades to a legacy string filter with no
         # error anywhere (charter D52). Validate it against THIS project —
         # `get_dataset/2` scopes by project_id, so a `production` under another
         # project never satisfies this. The tuple tag is load-bearing: a bare
         # `%Tenancy.Dataset{} <- …` would fall into the `_` catch-all below and
         # report a dataset typo as "unauthorized".
         {:dataset, %Tenancy.Dataset{}} <- {:dataset, Tenancy.get_dataset(proj, dataset)} do
      # P5 live-push: subscribe to the workspace-scoped document mutation topic
      # so any create/update/delete in this (workspace, dataset) wakes the
      # channel to re-run its cached query. The workspace-scoped topic mirrors
      # the one the Listen SSE endpoint uses, so the tenant boundary already
      # enforced by `tap_broadcast` is preserved — a write in another workspace
      # never reaches this channel even though both share the dataset string.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{dataset}")

      socket =
        socket
        |> assign(:current_workspace, ws)
        |> assign(:current_project, proj)
        |> assign(:dataset, dataset)
        |> assign(:last_query, nil)

      {:ok, socket}
    else
      [_ | _] -> {:error, %{reason: "bad_topic"}}
      {:dataset, _} -> {:error, %{reason: "unknown_dataset"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("query", %{"q" => q} = params, socket) do
    seq = params["seq"]

    # Mirror SearchController: ONLY a truly empty string is "no query". A single
    # space is the BROWSE sentinel (enumerate + facet the dataset) — it must pass
    # through to the engine, not be trimmed away to empty (that returned 0 hits
    # for the empty box, which should instead show the full browseable list).
    case to_string(q) do
      "" ->
        # Empty query — clear any cached live-push state so we don't wake the
        # channel for the empty box.
        socket = assign(socket, :last_query, nil)
        {:reply, {:ok, empty_reply(seq, "")}, socket}

      query ->
        opts_base = [
          type: params["type"],
          types: parse_types(params["types"]),
          # PINNED — never read from `params`. See the moduledoc.
          perspective: :published,
          limit: clamp_limit(params["limit"]),
          offset: parse_int(params["offset"], 0),
          engine: params["engine"] || "indx"
        ]

        opts = opts_base ++ scope_opts(socket)

        {docs, count, meta} = Content.search_documents(query, socket.assigns.dataset, opts)

        reply =
          build_reply(seq, query, docs, count, meta, socket, params["fields"], params["view"])

        # Cache the latest query parameters so a downstream
        # `{:document_changed, _}` PubSub message can re-run the SAME search
        # without the client re-pushing. `opts_base` excludes the tenancy scope
        # — that is re-derived from the socket on each re-run via `scope_opts/1`
        # so a workspace move (today purely defensive) cannot stale-pin the old
        # tenant filter. `view` rides along so a brief subscriber's live pushes
        # stay brief.
        socket =
          assign(socket, :last_query, %{
            seq: seq,
            query: query,
            opts_base: opts_base,
            fields: params["fields"],
            view: params["view"]
          })

        {:reply, {:ok, reply}, socket}
    end
  end

  @impl true
  def handle_info({:document_changed, _msg}, socket) do
    case socket.assigns[:last_query] do
      nil ->
        {:noreply, socket}

      %{seq: seq, query: query, opts_base: opts_base} = last ->
        opts = opts_base ++ scope_opts(socket)

        {docs, count, meta} =
          Content.search_documents(query, socket.assigns.dataset, opts)

        push(
          socket,
          "results",
          build_reply(seq, query, docs, count, meta, socket, last[:fields], last[:view])
        )

        {:noreply, socket}
    end
  end

  # Defensive: ignore any other message that may end up in the channel's
  # mailbox (e.g. a future PubSub fan-out we haven't filtered). The channel
  # must never crash on an unexpected message.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ONE shared envelope builder (AXI R3) — the same `HitEnvelope.build/5` the
  # HTTP routes consume, so the client renders identically whether the hit came
  # over HTTP or the socket. BOTH call sites (the "query" reply and the P5
  # live-push) go through this function. Per-type schema resolution drops a
  # non-encrypted private/owner_only/readable_by field for a non-authorized
  # subscriber; `fields` mirrors the HTTP `?fields=` allowlist; `view: "brief"`
  # returns brief hit cards (id/type/title/slug/snippet/highlights).
  defp build_reply(seq, query, docs, count, meta, socket, fields, view) do
    caller_context = CallerContext.from_conn(socket)

    docs
    |> HitEnvelope.build(count, query, meta,
      caller_context: caller_context,
      schema_resolver: schema_resolver(socket),
      fields: fields,
      view: view
    )
    |> Map.put(:seq, seq)
  end

  # Per-type schema resolver memoised by `Envelope.render_many_by_type` across
  # the live result set. Tenancy scope is re-derived from the socket each push,
  # matching how the search opts are rebuilt. nil on an unresolved type leaves
  # the ciphertext guard as the floor.
  defp schema_resolver(socket) do
    dataset = socket.assigns.dataset
    opts = scope_opts(socket)

    fn type ->
      case Content.Schema.get_schema_for_redaction(type, dataset, opts) do
        {:ok, schema} -> schema
        _ -> nil
      end
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
