defmodule BarkparkCloud.StudioLinkFakeHttpClient do
  @moduledoc """
  Test double for the dwb-7 studio-link transport (`:studio_link_http_client`) —
  the instance-side `POST /v1/auth/login-tickets` call. Same process-dictionary
  design as `BarkparkCloud.Notifications.FakeHttpClient` (Plug.Test runs the
  router in the test process), so it is parallel-safe under `async: true`:
  record requests, pop programmed responses, no global state.

  Usage:

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_x","expires_in":60})}}
      ])

  When the queue is empty it defaults to a successful 201 with ticket
  `"bplt_default-ticket"`.
  """

  @requests_key :studio_link_fake_requests
  @responses_key :studio_link_fake_responses

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
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_default-ticket","expires_in":60})}}
    end
  end
end
