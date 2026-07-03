defmodule BarkparkCloud.HetznerFakeHttpClient do
  @moduledoc """
  Test double for the Hetzner proxy's HTTP seam — wired in via
  `config :barkpark_cloud, :hetzner_http_client` (config/test.exs), same shape
  as `BarkparkCloud.Notifications.FakeHttpClient`. It runs IN the calling
  process (the router executes synchronously under `Plug.Test`), so it records
  requests and reads programmed responses straight out of the process
  dictionary — no GenServer, no global state, fully parallel-safe across
  `async: true` tests.

  Unlike the notifications fake (a FIFO queue), the overview fan-out hits NINE
  upstream paths in one request, so responses are programmed PER PATH:

      HetznerFakeHttpClient.program(%{
        "/v1/servers" => {:ok, %{status: 200, body: ~s({"servers":[...]})}},
        "/v1/volumes" => {:ok, %{status: 500, body: "{}"}}
      })

  `request/1` looks the URL's path up in the programmed map; an unprogrammed
  path defaults to `{:ok, %{status: 200, body: "{}"}}` (an empty upstream).
  """

  @requests_key :hetzner_fake_requests
  @responses_key :hetzner_fake_responses

  @doc "Program per-path responses. Resets the request log."
  def program(responses_by_path) when is_map(responses_by_path) do
    Process.put(@responses_key, responses_by_path)
    Process.put(@requests_key, [])
    :ok
  end

  @doc "The requests seen so far, in call order."
  def requests, do: Enum.reverse(Process.get(@requests_key, []))

  @doc "The HttpClient contract: record the request, return the path's programmed response."
  def request(%{url: url} = req) do
    Process.put(@requests_key, [req | Process.get(@requests_key, [])])

    path = URI.parse(url).path
    Map.get(Process.get(@responses_key, %{}), path, {:ok, %{status: 200, body: "{}"}})
  end
end
