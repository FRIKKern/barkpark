defmodule BarkparkWeb.DocumentSizeCapTest do
  @moduledoc """
  Owner ruling #39 (task-923e630674853500): a per-document size cap with a
  sane default, configurable, refused as a named 413 `document_too_large`.

  Before, no write door capped one document (HTTP accepted 100 MB), and every
  save copied the whole document into history and the event log.
  """
  # sync: swaps node-global Application env (`:barkpark, :max_document_bytes`)
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.DocumentSize

  @ds "test"
  @token "barkpark-test-document-size-cap"
  @cap 4_000

  setup do
    previous = Application.fetch_env(:barkpark, :max_document_bytes)
    Application.put_env(:barkpark, :max_document_bytes, @cap)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, :max_document_bytes, value)
        :error -> Application.delete_env(:barkpark, :max_document_bytes)
      end
    end)

    {:ok, _} =
      Auth.create_token(
        @token,
        "size-cap",
        @ds,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @ds
      )

    :ok
  end

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@ds}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp big(n), do: String.duplicate("x", n)

  test "the default cap is 10 MB and 0 or nil turns it off" do
    assert DocumentSize.default_max_bytes() == 10_000_000
    Application.put_env(:barkpark, :max_document_bytes, 0)
    assert DocumentSize.max_bytes() == nil
    Application.put_env(:barkpark, :max_document_bytes, nil)
    assert DocumentSize.max_bytes() == nil
  end

  test "a create over the cap answers 413 document_too_large and writes nothing",
       %{conn: conn} do
    resp =
      mutate(conn, [%{"create" => %{"_id" => "big-1", "_type" => "post", "body" => big(5_000)}}])

    assert resp.status == 413, resp.resp_body
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "document_too_large"
    assert error["details"]["limit_bytes"] == @cap
    assert error["details"]["size_bytes"] > @cap
    assert error["hint"] =~ "BARKPARK_MAX_DOCUMENT_BYTES"

    assert {:error, :not_found} = Content.get_document("drafts.big-1", "post", @ds)
  end

  test "a patch that grows a document over the cap is refused; the row keeps its bytes",
       %{conn: conn} do
    assert mutate(conn, [
             %{"create" => %{"_id" => "grow-1", "_type" => "post", "body" => "small"}}
           ]).status == 200

    resp =
      mutate(conn, [
        %{
          "patch" => %{
            "id" => "drafts.grow-1",
            "type" => "post",
            "set" => %{"body" => big(5_000)}
          }
        }
      ])

    assert resp.status == 413, resp.resp_body
    assert {:ok, doc} = Content.get_document("drafts.grow-1", "post", @ds)
    assert doc.content["body"] == "small"
  end

  test "a document under the cap is written as before", %{conn: conn} do
    resp =
      mutate(conn, [%{"create" => %{"_id" => "fits-1", "_type" => "post", "body" => big(1_000)}}])

    assert resp.status == 200, resp.resp_body
  end

  test "the context door refuses too, so Studio and plugin writes are covered" do
    assert {:error, %Ecto.Changeset{} = cs} =
             Content.create_document(
               "post",
               %{"doc_id" => "ctx-big", "title" => "t", "content" => %{"body" => big(5_000)}},
               @ds
             )

    assert {@cap, size} = DocumentSize.refusal(cs)
    assert size > @cap

    assert %{status: 413, code: "document_too_large"} =
             Barkpark.Content.Errors.to_envelope({:error, cs})
  end

  test "an update that leaves title and content alone is not measured" do
    Application.put_env(:barkpark, :max_document_bytes, nil)

    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "legacy-big", "title" => "t", "content" => %{"body" => big(5_000)}},
        @ds
      )

    Application.put_env(:barkpark, :max_document_bytes, @cap)

    cs = Barkpark.Content.Document.changeset(doc, %{status: "draft"})
    assert cs.valid?, inspect(cs.errors)
  end

  test "the data routes cap the request body at three documents", %{conn: conn} do
    resp =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/mutate/#{@ds}",
        Jason.encode!(%{"mutations" => [], "pad" => big(@cap * 3 + 100)})
      )

    assert resp.status == 413
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "payload_too_large"
  end
end
