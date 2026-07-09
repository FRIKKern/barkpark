defmodule BarkparkCloud.AzureRetailPricingFakeHttpClient do
  @moduledoc """
  Cross-process test double for the `BarkparkCloud.Azure.Pricing` transport seam.

  Serve-stale-while-refreshing means the injected transport no longer runs only
  in the calling process — a demand-triggered refresh fetches from a task under
  the Pricing GenServer, NOT the test process. A process-dictionary queue (the
  old shape) is invisible to that task (`$callers` carries no pdict), so the FIFO
  of programmed responses lives in a public NAMED ETS table this module owns
  instead. Whichever process fetches — the caller doing a synchronous
  absent-cache fetch, or the GenServer's background refresh — pops the same queue
  and records into the same request log.

      AzureRetailPricingFakeHttpClient.program([
        {:ok, %{status: 200, body: ~s({"Items":[…],"NextPageLink":"…"})}},
        {:ok, %{status: 200, body: ~s({"Items":[…])}}   # last page, no NextPageLink
      ])

  The table is created lazily by the first caller in a test (always the test
  process, via `program/1`) and dies with it, so each test starts from a clean
  slate. An empty queue (never programmed, or exhausted) returns
  `{:error, :not_programmed}` — a test that forgets to program the client sees a
  fetch FAILURE (which degrades to nil prices), never a silent 200.

  Its ONLY consumer is `azure_pricing_test.exs`.
  """

  @table :azure_retail_pricing_fake_http

  @doc "Program the FIFO page responses. Resets the request log."
  def program(responses) when is_list(responses) do
    ensure_table()
    :ets.insert(@table, {:queue, responses})
    :ets.insert(@table, {:requests, []})
    :ok
  end

  @doc "The request maps seen so far, in call order."
  def requests do
    ensure_table()

    case :ets.lookup(@table, :requests) do
      [{:requests, reqs}] -> Enum.reverse(reqs)
      _ -> []
    end
  end

  @doc "The transport contract: record the request, pop and return the next programmed response."
  def request(req) do
    ensure_table()

    prior =
      case :ets.lookup(@table, :requests) do
        [{:requests, reqs}] -> reqs
        _ -> []
      end

    :ets.insert(@table, {:requests, [req | prior]})

    case :ets.lookup(@table, :queue) do
      [{:queue, [response | rest]}] ->
        :ets.insert(@table, {:queue, rest})
        response

      _ ->
        {:error, :not_programmed}
    end
  end

  # Public named table so a background refresh in another process reads the same
  # queue. Tolerate a concurrent create (whoever wins owns it for the test).
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end
end
