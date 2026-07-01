defmodule BarkparkCloud.Notifications.FakeHttpClient do
  @moduledoc """
  Test double for `BarkparkCloud.Billing.HttpClient` — wired in via
  `config :barkpark_cloud, :notifications_http_client` (config/test.exs). It runs
  IN the calling process (tests drive `Dispatcher.deliver/4` synchronously, not via
  the supervised Task), so it records requests and reads programmed responses
  straight out of the process dictionary — no GenServer, no global state, fully
  parallel-safe across `async: true` tests.

  Usage in a test:

      FakeHttpClient.program([{:ok, %{status: 503}}, {:ok, %{status: 200}}])
      Dispatcher.deliver(team_id, cfg, "test", %{})
      assert length(FakeHttpClient.requests()) == 2

  Each `request/1` pops the next programmed response; when the queue is empty it
  defaults to `{:ok, %{status: 200, body: ""}}`.
  """

  @requests_key :notif_fake_requests
  @responses_key :notif_fake_responses

  @doc "Queue the responses `request/1` will return, in order. Resets the request log."
  def program(responses) when is_list(responses) do
    Process.put(@responses_key, responses)
    Process.put(@requests_key, [])
    :ok
  end

  @doc "The requests seen so far, in call order."
  def requests, do: Enum.reverse(Process.get(@requests_key, []))

  @doc "The HttpClient contract: record the request, return the next programmed response."
  def request(req) do
    Process.put(@requests_key, [req | Process.get(@requests_key, [])])

    case Process.get(@responses_key, []) do
      [next | rest] ->
        Process.put(@responses_key, rest)
        next

      [] ->
        {:ok, %{status: 200, body: ""}}
    end
  end
end
