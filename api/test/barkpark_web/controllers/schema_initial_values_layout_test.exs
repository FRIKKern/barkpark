defmodule BarkparkWeb.SchemaInitialValuesLayoutTest do
  @moduledoc """
  task-28082a4cf187403d — `GET /v1/schemas/:dataset/:name` omitted
  `initialValues`, `layout` and `prefill`, although `create` already applies
  `initial_values` on a new document and `POST /v1/schemas/:dataset` already
  stores `layout`/`prefill` (the Expectation). A Studio reading a schema back
  had no way to show a non-empty default before a document's first write, and
  could not tell a PortableDoc type from the content model (FF3).

  `Content.Schema.serialize_schema_for_sdk/1` is the ONE function both
  `index`/`show` and the `upsert` echo call (pinned by
  `SchemaUpsertEchoTest`), so fixing it here fixes all three read surfaces at
  once — covered below for `show` specifically, since that is where the gap
  was found.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth

  @admin_token "barkpark-dev-token-schema-initial-values"

  setup do
    Auth.create_token(@admin_token, "dev", "schema-initial-values-test", [
      "read",
      "write",
      "admin"
    ])

    :ok
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  test "GET schema returns initialValues for post ({featured: false})", %{conn: conn} do
    body = %{
      "name" => "iv_post",
      "title" => "Post",
      "visibility" => "public",
      "fields" => [%{"name" => "featured", "type" => "boolean"}],
      "initial_values" => %{"featured" => false}
    }

    assert conn
           |> authed(@admin_token)
           |> post(~p"/v1/schemas/test", Jason.encode!(body))
           |> then(& &1.status) == 201

    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/iv_post")
      |> json_response(200)

    assert show["schema"]["initialValues"] == %{"featured" => false}
  end

  test "GET schema returns layout as POSTed (note: field title + region body)", %{conn: conn} do
    layout = [
      %{"kind" => "field", "name" => "title"},
      %{"kind" => "region", "name" => "body"}
    ]

    body = %{
      "name" => "iv_note",
      "title" => "Note",
      "visibility" => "public",
      "fields" => [%{"name" => "title", "type" => "string"}],
      "layout" => layout
    }

    assert conn
           |> authed(@admin_token)
           |> post(~p"/v1/schemas/test", Jason.encode!(body))
           |> then(& &1.status) == 201

    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/iv_note")
      |> json_response(200)

    assert show["schema"]["layout"] == layout
  end

  test "prefill round-trips too, verbatim as POSTed", %{conn: conn} do
    body = %{
      "name" => "iv_prefill",
      "title" => "Prefill",
      "visibility" => "public",
      "fields" => [%{"name" => "status", "type" => "string"}],
      "prefill" => %{"status" => "draft"}
    }

    assert conn
           |> authed(@admin_token)
           |> post(~p"/v1/schemas/test", Jason.encode!(body))
           |> then(& &1.status) == 201

    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/iv_prefill")
      |> json_response(200)

    assert show["schema"]["prefill"] == %{"status" => "draft"}
  end

  test "omitting all three defaults them to empty, never nil", %{conn: conn} do
    body = %{
      "name" => "iv_bare",
      "title" => "Bare",
      "visibility" => "public",
      "fields" => [%{"name" => "title", "type" => "string"}]
    }

    assert conn
           |> authed(@admin_token)
           |> post(~p"/v1/schemas/test", Jason.encode!(body))
           |> then(& &1.status) == 201

    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/iv_bare")
      |> json_response(200)

    assert show["schema"]["initialValues"] == %{}
    assert show["schema"]["layout"] == []
    assert show["schema"]["prefill"] == %{}
  end

  test "the upsert 201 echo carries the same three keys as the GET, byte for byte", %{
    conn: conn
  } do
    body = %{
      "name" => "iv_echo",
      "title" => "Echo",
      "visibility" => "public",
      "fields" => [%{"name" => "featured", "type" => "boolean"}],
      "initial_values" => %{"featured" => false},
      "layout" => [%{"kind" => "field", "name" => "featured"}],
      "prefill" => %{"featured" => false}
    }

    created =
      conn
      |> authed(@admin_token)
      |> post(~p"/v1/schemas/test", Jason.encode!(body))
      |> json_response(201)

    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/iv_echo")
      |> json_response(200)

    for key <- ["initialValues", "layout", "prefill"] do
      assert created[key] == show["schema"][key], "mismatch on #{key}"
    end
  end
end
