defmodule BarkparkWeb.SchemaRuleMessagesEchoTest do
  @moduledoc """
  task-bd4b556125fe702e — "a pattern rule and a cross-field rule can declare
  the message editors see, and the schema read returns it" (Gyldendal Agency
  Studio parity: ISBN pattern, bookRow cross-field messages).

  Both halves were ALREADY fully implemented and already unit-tested at the
  `Barkpark.Content.Validation` / `CrossValidator` level before this test:

    * a field's `"validation"` rule map's `"message"` key already replaces
      every generated finding's wording (`Validation.apply_message/2`), and a
      pattern rule is no exception — `validation_nested_tree_test.exs`'s
      `buttonHref` field (`"pattern" => "^/", "message" => "Lenken må starte
      med /."`) already proves the VALIDATOR half.
    * `cross_validations` entries already carry a `"title"` the Studio
      violation banner already reads (`editor.ex:1203`,
      `v["title"] || v["name"]`), and `CrossValidator` already evaluates them.

  What had never been pinned down as a regression guard is the WIRE contract
  this criterion names explicitly: that `POST /v1/schemas/:dataset` and
  `GET /v1/schemas/:dataset/:name` round-trip a rule's custom message
  byte-for-byte, for BOTH a pattern rule (per-field `validation.message`) and
  a cross-field rule (`cross_validations[].title`) — `serialize_field/1` and
  `serialize_schema_for_sdk/1` pass both through unchanged today, but nothing
  asserted that at the HTTP boundary. This test is that proof; it closes
  task-bd4b556125fe702e's last open criterion with evidence a future
  schema-serializer change can red against.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content

  @admin_token "barkpark-dev-token-schema-rule-messages"
  @isbn_message "ISBN må være 13 sifre"
  @bookrow_message "En rad uten kategori må ha en overskrift"

  setup do
    Auth.create_token(@admin_token, "dev", "schema-rule-messages-test", ["read", "write", "admin"])

    :ok
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  test "a pattern rule's custom message round-trips through write+read, and the validator uses it",
       %{conn: conn} do
    body = %{
      "name" => "srm_isbn_widget",
      "title" => "SRM ISBN Widget",
      "visibility" => "public",
      "fields" => [
        %{
          "name" => "isbn",
          "type" => "string",
          "validation" => %{"pattern" => "^[0-9]{13}$", "message" => @isbn_message}
        }
      ]
    }

    created =
      conn
      |> authed(@admin_token)
      |> post(~p"/v1/schemas/test", Jason.encode!(body))
      |> json_response(201)

    field = Enum.find(created["fields"], &(&1["name"] == "isbn"))
    assert field["validation"]["message"] == @isbn_message

    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/srm_isbn_widget")
      |> json_response(200)

    show_field = Enum.find(show["schema"]["fields"], &(&1["name"] == "isbn"))
    assert show_field["validation"]["message"] == @isbn_message

    # The message the schema read promised is the SAME text the validator
    # actually reports on a violation — a client can trust what it read.
    {:ok, schema} = Content.get_schema("srm_isbn_widget", "test")

    assert Content.Validation.check(%{"isbn" => "not-an-isbn"}, nil, schema).errors == %{
             "isbn" => [@isbn_message]
           }
  end

  test "a cross-field rule's message (title) round-trips through write+read", %{conn: conn} do
    body = %{
      "name" => "srm_bookrow_widget",
      "title" => "SRM Bookrow Widget",
      "visibility" => "public",
      "fields" => [
        %{"name" => "category", "type" => "string"},
        %{"name" => "heading", "type" => "string"}
      ],
      "cross_validations" => [
        %{
          "name" => "heading_required_without_category",
          "title" => @bookrow_message,
          "rule" => %{"all" => [%{"field" => "category", "operator" => "empty"}]},
          "level" => "error",
          "fields" => ["heading"]
        }
      ]
    }

    created =
      conn
      |> authed(@admin_token)
      |> post(~p"/v1/schemas/test", Jason.encode!(body))
      |> json_response(201)

    assert [cv] = created["crossValidations"]
    assert cv["title"] == @bookrow_message

    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/srm_bookrow_widget")
      |> json_response(200)

    assert [show_cv] = show["schema"]["crossValidations"]
    assert show_cv["title"] == @bookrow_message
  end
end
