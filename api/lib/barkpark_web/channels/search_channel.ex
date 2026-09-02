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

  ## The per-socket query throttle (and why it cannot be a plug)

  A `"query"` frame runs a full `Content.search_documents/3` against Postgres.
  The HTTP twin of that exact capability is capped at 300 reads/min by
  `BarkparkWeb.Plugs.RateLimit`, mounted on both search routes. **A channel
  frame never reaches it**: `socket "/socket", BarkparkWeb.UserSocket`
  (endpoint.ex) enters BELOW the router, so no plug in the `:api` /
  `:scoped_api` pipelines runs, and no plug could be mounted that would. The
  cap therefore has to live here, in the channel, per socket — which is
  precisely the shape both sibling channels already use off
  `System.monotonic_time/1`: `PulseChannel`'s `"cursor"` (80ms) and
  `QuizChannel`'s `"submit_answer"` / `"cursor"` / `"hover"` (250/33/50ms).

  One difference from the siblings, deliberate: this bucket carries BURST
  credit rather than a bare minimum interval. Their frames are fire-and-forget
  (a PubSub broadcast, a GenServer cast) and a dropped one costs nothing; a
  dropped `"query"` frame darks a keystroke on the flagship search-as-you-type
  surface the charter's D38/D52 acceptance requires to keep working. So the
  bucket is sized so human typing never touches it (`:query_burst` frames of
  credit) while the SUSTAINED rate is exactly the 300/min the HTTP twin
  already enforces. Over budget the frame is refused with a named
  `"rate_limited"` reason rather than dropped silently, so the client can back
  off instead of rendering a stale box.

  Tunable via `config :barkpark, :search_channel, query_per_minute: _,
  query_burst: _`.

  ### What this does NOT cap

  One channel process serialises its own frames, so the per-socket bucket
  bounds one socket. The unbounded quantity is the number of SOCKETS, and that
  is capped separately, at connect, in `BarkparkWeb.UserSocket` — see its
  moduledoc. Neither cap subsumes the other.
  """
  use Phoenix.Channel

  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Content.CallerContext
  alias Barkpark.Search.HitEnvelope

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @max_limit 100

  # Sustained rate, deliberately EQUAL to `Plugs.RateLimit`'s read budget
  # (rate_limit.ex `default_per_minute(_, :read)`), so the socket door and the
  # HTTP door price the same capability the same way.
  @default_query_per_minute 300
  # Burst credit: how many back-to-back frames a socket may spend before the
  # sustained rate binds. Sized for a human hammering a search box, not for a
  # loop.
  @default_query_burst 30

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
        # Seed the query bucket FULL, off a real monotonic reading. Note the
        # lesson pulse_channel.ex records in the same place: monotonic time is
        # usually NEGATIVE, so a `0` sentinel would look like an enormous
        # elapsed interval (or, for the mirror bug, throttle forever). Take the
        # actual clock.
        |> assign(:query_allowance, query_burst() * 1.0)
        |> assign(:query_last_ms, System.monotonic_time(:millisecond))

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
        # The throttle is charged HERE and not on the `""` branch above: the
        # empty branch answers from a literal and never touches Postgres, so
        # billing it would spend a real search's budget on a frame that costs
        # nothing. What is being rationed is `Content.search_documents/3`.
        case take_query_token(socket) do
          {:rate_limited, retry_after_ms, socket} ->
            {:reply,
             {:error, %{reason: "rate_limited", retry_after_ms: retry_after_ms, seq: seq}},
             socket}

          {:ok, socket} ->
            run_query(query, seq, params, socket)
        end
    end
  end

  defp run_query(query, seq, params, socket) do
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

  # The bucket itself: monotonic-time refill, burst-capped, held in socket
  # assigns so it is per-socket and dies with the socket.
  #
  # Two details that are easy to get wrong and are load-bearing here:
  #
  #   * `query_last_ms` advances on a REFUSED frame too. `RateLimiter.debit/4`
  #     famously does not (its own moduledoc records the consequence), which
  #     freezes the clock at the last ADMITTED frame; here the elapsed interval
  #     is what earns credit, so freezing it would mean a socket that keeps
  #     hammering never earns its way back — a refusal would be permanent under
  #     sustained load.
  #   * a refused frame CARRIES its fractional allowance forward instead of
  #     resetting it, so being denied costs nothing but the frame.
  defp take_query_token(socket) do
    burst = query_burst()
    refill_per_ms = query_per_minute() / 60_000
    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:query_last_ms] || now
    held = socket.assigns[:query_allowance] || burst * 1.0

    allowance = min(burst * 1.0, held + (now - last) * refill_per_ms)
    socket = assign(socket, :query_last_ms, now)

    if allowance >= 1.0 do
      {:ok, assign(socket, :query_allowance, allowance - 1.0)}
    else
      retry_after_ms = ceil((1.0 - allowance) / refill_per_ms)
      {:rate_limited, retry_after_ms, assign(socket, :query_allowance, allowance)}
    end
  end

  defp query_per_minute do
    :barkpark
    |> Application.get_env(:search_channel, [])
    |> Keyword.get(:query_per_minute, @default_query_per_minute)
    |> max(1)
  end

  defp query_burst do
    :barkpark
    |> Application.get_env(:search_channel, [])
    |> Keyword.get(:query_burst, @default_query_burst)
    |> max(1)
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
      case Content.get_schema(type, dataset, opts) do
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
