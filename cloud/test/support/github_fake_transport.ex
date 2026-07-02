defmodule BarkparkCloud.GitHubFakeTransport do
  @moduledoc """
  Test double for the `GitHub.Real` HTTP transport (`:http_client`) — the same
  process-dictionary design as `StudioLinkFakeHttpClient` /
  `Notifications.FakeHttpClient`, so it is parallel-safe under `async: true`
  (the code under test runs in the test process): record requests, pop programmed
  responses, no global state.

  Usage:

      GitHubFakeTransport.program([
        {:ok, %{status: 201, body: ~s({"token":"ghs_live_x","expires_at":"2026-01-01T00:00:00Z"})}}
      ])

      # then wire it into GitHub.Real:
      #   http_client: &GitHubFakeTransport.request/1

  With an empty queue it defaults to a generic 200 `{}` so a call never crashes.
  """

  @requests_key :github_fake_transport_requests
  @responses_key :github_fake_transport_responses

  @doc "Queue the responses `request/1` returns, in order. Resets the request log."
  def program(responses) when is_list(responses) do
    Process.put(@responses_key, responses)
    Process.put(@requests_key, [])
    :ok
  end

  @doc "The requests seen so far, in call order."
  def requests, do: Enum.reverse(Process.get(@requests_key, []))

  @doc "The single most recent request (or nil)."
  def last_request, do: List.last(requests())

  @doc "The transport contract: record the request, return the next programmed response."
  def request(req) do
    Process.put(@requests_key, [req | Process.get(@requests_key, [])])

    case Process.get(@responses_key, []) do
      [next | rest] ->
        Process.put(@responses_key, rest)
        next

      [] ->
        {:ok, %{status: 200, body: "{}"}}
    end
  end
end
