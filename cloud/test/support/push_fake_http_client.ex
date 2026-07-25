defmodule BarkparkCloud.PushFakeHttpClient do
  @moduledoc """
  Process-local fake `BarkparkCloud.Push.HTTP` — the push relay's HTTP BOUNDARY.

  Wired as `:push_http_client` in config/test.exs. This is what lets the REAL
  `Push.Adapters.APNS` / `Push.Adapters.FCM` run end-to-end in the suite: the
  ES256/RS256 signing, the URL construction, the header set, the JSON body and
  the status→verdict mapping all execute for real; only the socket is fake. An
  adapter test that instead faked `Push.Adapter` would be asserting on its own
  stub.

      PushFakeHttpClient.program(fn req ->
        assert req.url =~ "/3/device/"
        {:ok, %{status: 200, headers: [{"apns-id", "abc"}], body: ""}}
      end)

  Or program a queue of canned responses, consumed in order (the FCM path makes
  two requests per send — OAuth exchange, then messages:send):

      PushFakeHttpClient.program([
        {:ok, %{status: 200, headers: [], body: ~s({"access_token":"at","expires_in":3599})}},
        {:ok, %{status: 200, headers: [], body: ~s({"name":"projects/p/messages/1"})}}
      ])

  Unprogrammed, every request raises — a test that reaches the network by
  accident should fail loudly, not silently pass on a default 200.
  """

  @behaviour BarkparkCloud.Push.HTTP

  @responder_key {__MODULE__, :responder}
  @requests_key {__MODULE__, :requests}

  @doc """
  Program the fake: either a 1-arity function called with each request, or a
  LIST of `{:ok, response} | {:error, reason}` consumed in order.
  """
  def program(fun) when is_function(fun, 1), do: Process.put(@responder_key, fun)
  def program(responses) when is_list(responses), do: Process.put(@responder_key, responses)

  @doc "Every request issued in this process, oldest first."
  def requests, do: Process.get(@requests_key, []) |> Enum.reverse()

  @doc "Clear programmed responses and recorded requests."
  def reset do
    Process.delete(@responder_key)
    Process.delete(@requests_key)
    :ok
  end

  @impl true
  def request(request) do
    Process.put(@requests_key, [request | Process.get(@requests_key, [])])

    case Process.get(@responder_key) do
      fun when is_function(fun, 1) ->
        fun.(request)

      [next | rest] ->
        Process.put(@responder_key, rest)
        next

      [] ->
        raise "PushFakeHttpClient: response queue exhausted for #{inspect(request.url)}"

      nil ->
        raise "PushFakeHttpClient: unprogrammed request to #{inspect(request.url)} — " <>
                "call PushFakeHttpClient.program/1 first"
    end
  end
end
