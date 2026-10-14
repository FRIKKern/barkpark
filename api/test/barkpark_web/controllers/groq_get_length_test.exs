defmodule BarkparkWeb.GroqGetLengthTest do
  @moduledoc """
  A GROQ query sent as GET through a real Bandit listener, with the HTTP/1
  options config/runtime.exs gives the endpoint. `@sanity/client` keeps a
  query on GET until its encoded query and params pass 11,264 characters, so
  every such URL must answer. Bandit's default request line of 10,000 bytes
  answered 414 between the two.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_get"
  @ceiling 32_768

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-get", name: "GROQ get"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} = Content.create_document("post", %{"_id" => "a", "n" => 1}, @dataset, scope)
    {:ok, _} = Content.publish_document("a", "post", @dataset, scope)

    token = "groq-get-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "groq get", @dataset, ["read"], ws.id)

    {:ok, token: token, port: start_listener!()}
  end

  test "a GET whose encoded query string is 11,264 characters answers 200",
       %{token: token, port: port} do
    search = search_of_length(11_264)
    assert byte_size(search) == 11_264

    assert {200, body} = raw_get(port, path() <> "?" <> search, token)
    assert %{"result" => ["a"]} = Jason.decode!(body)
  end

  test "a GET target of 16 KB and one at the ceiling answer 200", %{token: token, port: port} do
    for target_size <- [16_384, @ceiling - byte_size("GET ") - byte_size(" HTTP/1.1\r\n")] do
      search = search_of_length(target_size - byte_size(path()) - 1)
      target = path() <> "?" <> search
      assert byte_size(target) == target_size

      {status, _body} = raw_get(port, target, token)
      assert status == 200, "target of #{target_size} bytes"
    end
  end

  test "one byte past the ceiling answers 414", %{token: token, port: port} do
    target_size = @ceiling - byte_size("GET ") - byte_size(" HTTP/1.1\r\n") + 1
    target = path() <> "?" <> search_of_length(target_size - byte_size(path()) - 1)

    assert {414, ""} = raw_get(port, target, token)
  end

  defp path, do: "/w/groq-get/p/site/v2025-02-19/data/query/#{@dataset}"

  # `query=<groq>&returnQuery=false`, URL-encoded as URLSearchParams does,
  # padded inside a string literal to exactly `size` bytes.
  defp search_of_length(size) do
    build = fn pad ->
      query = ~s'*[_type == "post" && n == 1 && title != "#{String.duplicate("x", pad)}"]._id'
      URI.encode_query(%{"query" => query, "returnQuery" => "false"}, :www_form)
    end

    pad = size - byte_size(build.(0))
    search = build.(pad)
    ^size = byte_size(search)
    search
  end

  defp start_listener! do
    {:ok, probe} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(probe)
    :ok = :gen_tcp.close(probe)

    http = Application.get_env(:barkpark, BarkparkWeb.Endpoint)[:http]

    start_supervised!({
      Bandit,
      plug: BarkparkWeb.Endpoint,
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: port,
      http_1_options: Keyword.fetch!(http, :http_1_options),
      thousand_island_options: [shutdown_timeout: 250]
    })

    port
  end

  # Status and body of one GET over a raw socket; the server closes or sets
  # content-length, and the body is read to that length.
  defp raw_get(port, target, token) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 10_000)

    request = [
      "GET ",
      target,
      " HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer ",
      token,
      "\r\nconnection: close\r\n\r\n"
    ]

    :ok = :gen_tcp.send(sock, request)
    response = read_all(sock, "")
    :gen_tcp.close(sock)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1." <> <<_minor, " ", status::binary>> | _] = String.split(head, "\r\n")
    {status |> String.slice(0, 3) |> String.to_integer(), body}
  end

  defp read_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> read_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
