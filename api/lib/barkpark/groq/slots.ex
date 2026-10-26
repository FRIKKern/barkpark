defmodule Barkpark.Groq.Slots do
  @moduledoc """
  How many GROQ queries evaluate at once on this node.

  Each query runs in a process with a `:max_heap_bytes` limit (512 MiB by
  default), and nothing capped how many ran together. A Next.js build
  prerenders pages in parallel, and on a small Cloud box (gyl: 2 cores,
  3.8 GB, no swap) enough broad queries at once can take the memory the
  service needs.

  `acquire/0` takes a slot for the calling process. When every slot is held
  it retries until `:queue_ms` (5_000) has passed and then answers
  `{:error, :busy}`, which the endpoint sends as 503 with `Retry-After`. The
  caller releases with `release/0` in an `after`; this GenServer also
  monitors each holder, so a holder that dies without running `after` frees
  its slot on the `:DOWN`.

  The limit is `config :barkpark, Barkpark.Groq, max_concurrent: n`. By
  default it is the number of `:max_heap_bytes` heaps that fit in half the
  machine's memory, at most two per scheduler and at least one. A
  non-positive value turns the cap off. When this process is not running,
  `acquire/0` admits the query.
  """

  use GenServer
  require Logger

  @retry_ms 25

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Take a slot for the calling process: `:ok` or `{:error, :busy}`."
  @spec acquire() :: :ok | {:error, :busy}
  def acquire do
    case limit() do
      n when is_integer(n) and n > 0 ->
        deadline = System.monotonic_time(:millisecond) + queue_ms()
        acquire(n, deadline)

      _ ->
        :ok
    end
  end

  defp acquire(n, deadline) do
    case GenServer.call(__MODULE__, {:acquire, self(), n}) do
      :ok ->
        :ok

      :full ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :busy}
        else
          Process.sleep(@retry_ms)
          acquire(n, deadline)
        end
    end
  catch
    :exit, reason ->
      Logger.warning("GROQ slots unavailable (#{inspect(reason)}); admitting the query")
      :ok
  end

  @doc "Release the calling process's slot. Idempotent."
  @spec release() :: :ok
  def release do
    GenServer.call(__MODULE__, {:release, self()})
  catch
    :exit, _reason -> :ok
  end

  @doc "The number of slots held now."
  @spec held() :: non_neg_integer()
  def held, do: GenServer.call(__MODULE__, :held)

  @doc "The slot limit in effect (see the moduledoc)."
  @spec limit() :: integer()
  def limit do
    case Application.get_env(:barkpark, Barkpark.Groq, [])[:max_concurrent] do
      n when is_integer(n) ->
        n

      _ ->
        case :persistent_term.get({__MODULE__, :default}, nil) do
          nil -> tap(default_limit(), &:persistent_term.put({__MODULE__, :default}, &1))
          n -> n
        end
    end
  end

  @doc false
  def default_limit(total_memory \\ total_memory(), heap_bytes \\ heap_bytes()) do
    by_memory = if total_memory, do: div(div(total_memory, 2), heap_bytes), else: 4
    by_cpu = 2 * System.schedulers_online()
    by_memory |> min(by_cpu) |> max(1)
  end

  defp heap_bytes,
    do: Application.get_env(:barkpark, Barkpark.Groq, [])[:max_heap_bytes] || 536_870_912

  defp queue_ms, do: Application.get_env(:barkpark, Barkpark.Groq, [])[:queue_ms] || 5_000

  defp total_memory do
    data = :memsup.get_system_memory_data()
    data[:system_total_memory] || data[:total_memory]
  catch
    _, _ -> nil
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, pid, n}, _from, holders) do
    cond do
      Map.has_key?(holders, pid) -> {:reply, :ok, holders}
      map_size(holders) >= n -> {:reply, :full, holders}
      true -> {:reply, :ok, Map.put(holders, pid, Process.monitor(pid))}
    end
  end

  def handle_call({:release, pid}, _from, holders) do
    case Map.pop(holders, pid) do
      {nil, holders} ->
        {:reply, :ok, holders}

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, holders}
    end
  end

  def handle_call(:held, _from, holders), do: {:reply, map_size(holders), holders}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, holders),
    do: {:noreply, Map.delete(holders, pid)}
end
