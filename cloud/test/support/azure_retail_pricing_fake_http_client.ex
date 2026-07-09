defmodule BarkparkCloud.AzureRetailPricingFakeHttpClient do
  @moduledoc """
  Test double for the `BarkparkCloud.Azure.Pricing` transport seam — same
  in-process, process-dictionary shape as `HetznerFakeHttpClient`. The Retail
  Prices client fetches pages SEQUENTIALLY in the CALLING process (it follows
  `NextPageLink` in a tail loop), so a FIFO queue of programmed responses,
  popped one per `request/1`, replays a multi-page fetch deterministically with
  ZERO network and no GenServer.

      AzureRetailPricingFakeHttpClient.program([
        {:ok, %{status: 200, body: ~s({"Items":[…],"NextPageLink":"…"})}},
        {:ok, %{status: 200, body: ~s({"Items":[…])}}   # last page, no NextPageLink
      ])

  An empty queue (never programmed, or exhausted) returns
  `{:error, :not_programmed}` — so a test that forgets to program the client
  sees a fetch FAILURE (which degrades to nil prices), never a silent 200.
  """

  @queue_key :azure_pricing_fake_queue
  @requests_key :azure_pricing_fake_requests

  @doc "Program the FIFO page responses. Resets the request log."
  def program(responses) when is_list(responses) do
    Process.put(@queue_key, responses)
    Process.put(@requests_key, [])
    :ok
  end

  @doc "The request maps seen so far, in call order."
  def requests, do: Enum.reverse(Process.get(@requests_key, []))

  @doc "The transport contract: record the request, pop and return the next programmed response."
  def request(req) do
    Process.put(@requests_key, [req | Process.get(@requests_key, [])])

    case Process.get(@queue_key, []) do
      [response | rest] ->
        Process.put(@queue_key, rest)
        response

      [] ->
        {:error, :not_programmed}
    end
  end
end
