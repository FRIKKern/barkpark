defmodule BarkparkWeb.EndpointDataReadTimeoutTest do
  @moduledoc """
  task-1e302921c7545cb0: a /v1/data body can be 30 MB, and Bandit gives each
  1 MB piece of it `read_timeout` to arrive. With Plug's 15 s default the first
  30 MB import batch to a new box ended in "Body read timeout" after 16 s. The
  document data routes now wait 60 s per piece; other routes keep 15 s.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Endpoint

  defp conn_for(path), do: Plug.Test.conn(:post, path)

  test "the document data routes wait 60 s for each piece of the body" do
    for path <- [
          "/v1/data/mutate/production",
          "/w/default/p/default/v1/data/mutate/production"
        ] do
      assert Endpoint.body_read_timeout(conn_for(path)) == 60_000, path
    end
  end

  test "other routes keep Plug's 15 s" do
    for path <- [
          "/v1/tickets",
          "/v1/schemas/production",
          "/v1/plugins/forms/w/a/p/b/d/c/sites/s/submissions"
        ] do
      assert Endpoint.body_read_timeout(conn_for(path)) == 15_000, path
    end
  end

  test "a mutate request still parses its JSON body" do
    conn =
      Plug.Test.conn(:post, "/v1/data/mutate/production", ~s({"mutations":[]}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    parsed =
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(
          parsers: [:json],
          json_decoder: Jason,
          read_timeout: Endpoint.body_read_timeout(conn)
        )
      )

    assert parsed.body_params == %{"mutations" => []}
  end
end
