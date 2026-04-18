defmodule BarkparkWeb.Contract.MetaTest do
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias BarkparkWeb.MetaController

  test "returns handshake envelope with all 4 keys and parseable serverTime" do
    conn = Phoenix.ConnTest.build_conn(:get, "/v1/meta")
    conn = MetaController.index(conn, %{})

    body = json_response(conn, 200)

    assert Map.has_key?(body, "minApiVersion")
    assert Map.has_key?(body, "maxApiVersion")
    assert Map.has_key?(body, "serverTime")
    assert Map.has_key?(body, "currentDatasetSchemaHash")

    assert {:ok, _dt, _} = DateTime.from_iso8601(body["serverTime"])
    assert is_map(body["currentDatasetSchemaHash"])
  end

  test "with dataset param returns a 16-char hex hash string" do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      "test"
    )

    conn = Phoenix.ConnTest.build_conn(:get, "/v1/meta?dataset=test")
    conn = MetaController.index(conn, %{"dataset" => "test"})

    body = json_response(conn, 200)
    hash = body["currentDatasetSchemaHash"]

    assert is_binary(hash)
    assert String.length(hash) == 16
    assert hash =~ ~r/^[0-9a-f]{16}$/
  end
end
