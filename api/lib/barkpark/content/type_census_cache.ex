defmodule Barkpark.Content.TypeCensusCache do
  @moduledoc """
  Keeps a workspace's type census (`Barkpark.Content.Analytics.type_census/2`)
  between document writes.

  ## Why

  Every Studio desk build counts the documents of every type in the dataset
  for the …Rest tier: one `GROUP BY type` over the whole dataset. A document
  open builds the desk in the dead render, and every navigation in the
  connected Studio builds it again. On a local workspace of 48,000 documents
  the count took 18 to 28 ms of the dead render.
  Between two document writes it returns the same rows every time.

  ## When an entry is still good

  This process subscribes to the document-list topics of a workspace and
  dataset before the first census of that pair is read, the same topics the
  connected Studio listens on (`Barkpark.Content.Broadcast`). It counts every
  announcement per workspace. An entry records the count from before its read
  and is served only while the count is unchanged, so a write that lands
  during the read costs the entry its next hit. A message without a workspace
  (a shared-layer document) moves every count.

  An entry also lives `@ttl_ms` at most, for a write that announces nothing.

  ## What is never cached

    * A grant-scoped census. It is narrowed by the caller's grants.
    * A census with no workspace id.
    * A read inside a transaction. It can see its own uncommitted writes.
      The caller checks that (`Analytics.type_census/2`), so this process
      never names the repo.

  Only the unnarrowed rows are kept. The ownership narrowing in
  `Analytics.type_census/2` runs on every call, as before.

  ## Disabled in `:test`

  `config/test.exs` turns it off: fixtures write documents without an
  announcement, and an entry must not outlive the sandbox that read it.
  `type_census_cache_test.exs` turns it on.
  """

  use GenServer

  alias Barkpark.Content.Broadcast

  @table :barkpark_type_census_cache
  @ttl_ms 30_000

  @doc """
  The census rows for `workspace_id` and `dataset`: the stored ones while no
  document of the workspace has been announced since they were read, else
  `read.()`, stored for the next caller.
  """
  @spec fetch(term(), String.t(), keyword(), (-> rows)) :: rows when rows: list()
  def fetch(workspace_id, dataset, opts, read) when is_function(read, 0) do
    with true <- cacheable?(workspace_id, dataset, opts),
         true <- watch(workspace_id, dataset),
         epoch when is_integer(epoch) <- epoch(workspace_id) do
      cached_fetch({:census, workspace_id, dataset}, epoch, read)
    else
      _ -> read.()
    end
  end

  @doc "Whether the cache is on (`config :barkpark, :type_census_cache`, default true)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:barkpark, :type_census_cache, true) == true

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  defp cacheable?(workspace_id, dataset, opts) do
    enabled?() and is_binary(workspace_id) and is_binary(dataset) and
      not Keyword.get(opts, :grant_scoped, false) and
      :ets.whereis(@table) != :undefined
  end

  defp cached_fetch(key, epoch, read) do
    now = System.monotonic_time(:millisecond)

    case safe(fn -> :ets.lookup(@table, key) end) do
      [{^key, ^epoch, rows, expires_at}] when expires_at > now ->
        rows

      _ ->
        rows = read.()
        safe(fn -> :ets.insert(@table, {key, epoch, rows, now + @ttl_ms}) end)
        rows
    end
  end

  # Subscribe before the caller reads. The fast path is one ETS lookup; the
  # first census of a workspace and dataset makes one call.
  defp watch(workspace_id, dataset) do
    case safe(fn -> :ets.member(@table, {:watched, workspace_id, dataset}) end) do
      true ->
        true

      _ ->
        try do
          GenServer.call(__MODULE__, {:watch, workspace_id, dataset}) == :ok
        catch
          :exit, _ -> false
        end
    end
  end

  defp epoch(workspace_id) do
    case safe(fn -> :ets.lookup(@table, {:epoch, workspace_id}) end) do
      [{_, n}] -> n
      _ -> nil
    end
  end

  # A table that vanished (a node without the application) is a cold cache.
  defp safe(fun) do
    fun.()
  rescue
    ArgumentError -> nil
  end

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{topics: MapSet.new()}}
  end

  @impl true
  def handle_call({:watch, workspace_id, dataset}, _from, state) do
    topics =
      Enum.reduce(
        [
          Broadcast.workspace_list_topic(dataset, workspace_id),
          Broadcast.global_list_topic(dataset)
        ],
        state.topics,
        fn topic, acc ->
          if MapSet.member?(acc, topic) do
            acc
          else
            :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
            MapSet.put(acc, topic)
          end
        end
      )

    :ets.insert_new(@table, {{:epoch, workspace_id}, 0})
    :ets.insert(@table, {{:watched, workspace_id, dataset}, true})
    {:reply, :ok, %{state | topics: topics}}
  end

  # Any document announcement. A `{:document_changed, msg}` names the
  # document's workspace, and that workspace's count moves. Anything else
  # moves every count; a moved count costs a miss, never a wrong answer.
  @impl true
  def handle_info({:document_changed, %{workspace_id: ws_id}}, state) when is_binary(ws_id) do
    bump(ws_id)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    for [ws_id] <- :ets.match(@table, {{:epoch, :"$1"}, :_}), do: bump(ws_id)
    {:noreply, state}
  end

  defp bump(ws_id) do
    key = {:epoch, ws_id}
    :ets.update_counter(@table, key, 1, {key, 0})
  end
end
