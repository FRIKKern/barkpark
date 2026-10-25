defmodule BarkparkWeb.Studio.ConnectHandoff do
  @moduledoc """
  Hands the Studio dead render's panes to the connected mount of the same
  page, so the connected mount does not read them again.

  ## Why

  A Studio document URL runs `PaneBuilder.build/3` twice: once in the dead
  render (the HTTP request) and once in the connected mount, a few hundred
  milliseconds later, with the same arguments. The build reads the desk tree,
  the type census, the current list page, the document and its schema. On a
  local copy of the gyldendal-no workspace that is about 30 queries and 75 ms
  of query time per connected mount (task-cca3c6d48e57097e). The browser
  waits for the connected mount before the editor is live.

  ## Who gets an entry

  The dead render stores its build result under the LiveView socket id. That
  id is random per dead render and is signed into the page's LiveView
  session, so only the connected mount of that same page presents it. The
  entry also records the principal, and the connected mount must present the
  same principal and the same build arguments, including the full scope opts
  and the Studio locale. Anything else is a miss, and a miss builds as before.

  Never stored: an anonymous caller, a caller with grants, a grant-scoped
  read, and a preview token that names documents. Those reads are narrowed by
  per-caller state this module does not fingerprint.

  ## When an entry is still good

    * It is taken at most once. A reconnect of the same page reads afresh.
    * It lives `@ttl_ms` at most.
    * No document of its workspace has been announced since the dead render
      started reading. This process subscribes to the same document-list
      topics the connected Studio subscribes to, before the dead render reads,
      and counts every announcement per workspace.
      The entry keeps the count from before its read, and the connected mount
      uses it only while the count is unchanged. The connected mount itself
      subscribes before it takes the entry, so a write after that reaches it
      the usual way.
    * The schema version (`SchemaCatalogCache.version/0`) is unchanged.
    * The workspace and project rows have the `updated_at` they had.

  ## Disabled in `:test`

  `config/test.exs` turns it off, so every LiveView test still reads twice.
  `connect_handoff_test.exs` turns it on.
  """

  use GenServer

  alias Barkpark.Content.{Broadcast, CallerContext, SchemaCatalogCache, WriteScope}

  @table :barkpark_studio_connect_handoff
  @ttl_ms 10_000
  @max_entries 128
  @sweep_ms 30_000
  @tried_key {__MODULE__, :tried}

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Run `build` for a Studio pane rebuild, or answer it from the dead render.

  `socket` is the LiveView socket and `scope_opts` the read scope the build
  uses (`ScopeHelpers.scope_opts/1`). `args` is every input of the build,
  `scope_opts` included. On the dead render the result is stored for the
  connected mount. On the first rebuild of a connected socket a matching entry
  is taken and returned instead of calling `build`.
  """
  @spec build(Phoenix.LiveView.Socket.t(), keyword(), term(), (-> result)) :: result
        when result: term()
  def build(socket, scope_opts, args, build) when is_function(build, 0) do
    case handoff_scope(socket, scope_opts) do
      nil -> build.()
      scope -> do_build(socket, scope, scope_opts, args, build)
    end
  end

  @doc "Whether the handoff is on (`config :barkpark, :studio_connect_handoff`, default true)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:barkpark, :studio_connect_handoff, true) == true

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ── Build paths ────────────────────────────────────────────────────────

  defp do_build(socket, scope, scope_opts, args, build) do
    if Phoenix.LiveView.connected?(socket),
      do: connected_build(socket, scope, scope_opts, args, build),
      else: dead_build(socket, scope, scope_opts, args, build)
  end

  # The dead render: watch the topics, note the count, read, store.
  defp dead_build(socket, {owner, ws_id, dataset}, scope_opts, args, build) do
    with true <- watch(ws_id, dataset),
         epoch when is_integer(epoch) <- epoch(ws_id) do
      schema_version = schema_version(scope_opts)
      result = build.()

      store(socket.id, {owner, ws_id, dataset, args, schema_version, epoch}, result)
      result
    else
      _ -> build.()
    end
  end

  # The first rebuild of a connected socket. Later rebuilds (navigation, live
  # updates) always read.
  defp connected_build(socket, {owner, ws_id, dataset}, scope_opts, args, build) do
    if Process.get(@tried_key) do
      build.()
    else
      Process.put(@tried_key, true)

      case take(socket.id) do
        {{^owner, ^ws_id, ^dataset, ^args, schema_version, epoch}, result, expires_at} ->
          if now_ms() < expires_at and epoch(ws_id) == epoch and
               schema_version(scope_opts) == schema_version,
             do: emit(:hit, result),
             else: emit(:stale, build.())

        nil ->
          emit(:none, build.())

        _ ->
          emit(:mismatch, build.())
      end
    end
  end

  # `[:barkpark, :studio, :connect_handoff]` with `result` :hit, :stale (the
  # entry was too old or something it read changed), :mismatch (another
  # principal or other build arguments) or :none (no entry).
  defp emit(result, value) do
    :telemetry.execute([:barkpark, :studio, :connect_handoff], %{count: 1}, %{result: result})
    value
  end

  # {owner, workspace id, dataset} for an eligible socket, else nil. The
  # principal comes from the scope opts the build reads with, so this adds no
  # read of its own.
  defp handoff_scope(socket, scope_opts) do
    with true <- enabled?(),
         true <- table?(),
         id when is_binary(id) <- socket.id,
         %{id: ws_id} when is_binary(ws_id) <- socket.assigns[:current_workspace],
         dataset when is_binary(dataset) <- socket.assigns[:dataset],
         ^ws_id <- Keyword.get(scope_opts, :workspace_id),
         false <- Keyword.get(scope_opts, :grant_scoped, false),
         false <- Keyword.has_key?(scope_opts, :only_doc_ids),
         %CallerContext{grants: []} = ctx <- Keyword.get(scope_opts, :caller_context),
         true <- ctx.principal_type != :anonymous and (ctx.user_id || ctx.token_id) != nil do
      {{ctx.principal_type, ctx.user_id, ctx.token_id}, ws_id, dataset}
    else
      _ -> nil
    end
  end

  defp schema_version(scope_opts) do
    WriteScope.request_memo(scope_opts, {:schema_catalog_version}, &SchemaCatalogCache.version/0)
  end

  # ── Table ──────────────────────────────────────────────────────────────

  defp store(id, meta, result) do
    safe(fn ->
      if :ets.info(@table, :size) >= @max_entries, do: sweep(now_ms())

      if :ets.info(@table, :size) >= @max_entries,
        do: :ets.match_delete(@table, {{:entry, :_}, :_, :_, :_})

      :ets.insert(@table, {{:entry, id}, meta, result, now_ms() + @ttl_ms})
    end)
  end

  defp take(id) do
    case safe(fn -> :ets.take(@table, {:entry, id}) end) do
      [{{:entry, ^id}, meta, result, expires_at}] -> {meta, result, expires_at}
      _ -> nil
    end
  end

  defp epoch(ws_id) do
    case safe(fn -> :ets.lookup(@table, {:epoch, ws_id}) end) do
      [{_, n}] -> n
      _ -> nil
    end
  end

  # Subscribe this process to the topics before the caller reads. The fast
  # path is one ETS lookup; the first dead render of a workspace and dataset
  # makes one call.
  defp watch(ws_id, dataset) do
    case :ets.whereis(@table) != :undefined and :ets.member(@table, {:watched, ws_id, dataset}) do
      true ->
        true

      false ->
        try do
          GenServer.call(__MODULE__, {:watch, ws_id, dataset}) == :ok
        catch
          :exit, _ -> false
        end
    end
  end

  defp sweep(now) do
    :ets.select_delete(@table, [{{{:entry, :_}, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp safe(fun) do
    fun.()
  rescue
    ArgumentError -> nil
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{topics: %{}}}
  end

  @impl true
  def handle_call({:watch, ws_id, dataset}, _from, state) do
    key = {:epoch, ws_id}

    state =
      Enum.reduce(
        [Broadcast.workspace_list_topic(dataset, ws_id), Broadcast.global_list_topic(dataset)],
        state,
        fn topic, acc ->
          if Map.has_key?(acc.topics, topic) do
            acc
          else
            :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
            put_in(acc, [:topics, topic], dataset)
          end
        end
      )

    :ets.insert_new(@table, {key, 0})
    :ets.insert(@table, {{:watched, ws_id, dataset}, true})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    safe(fn -> sweep(now_ms()) end)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # Any document announcement. The `{:document_changed, msg}` payload names
  # the document's workspace; that workspace's count moves. A shared-layer
  # document (no workspace) can show on every desk, so it moves every count,
  # and so does a message of any other shape. A moved count costs a miss.
  def handle_info(msg, state) do
    case msg do
      {:document_changed, %{workspace_id: ws_id}} when is_binary(ws_id) -> bump({:epoch, ws_id})
      _ -> bump_all()
    end

    {:noreply, state}
  end

  defp bump(key), do: safe(fn -> :ets.update_counter(@table, key, 1, {key, 0}) end)

  defp bump_all do
    for [ws_id] <- :ets.match(@table, {{:epoch, :"$1"}, :_}), do: bump({:epoch, ws_id})
  end
end
