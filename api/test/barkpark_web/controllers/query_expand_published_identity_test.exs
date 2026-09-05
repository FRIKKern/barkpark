defmodule BarkparkWeb.QueryExpandPublishedIdentityTest do
  @moduledoc """
  Gyldendal field report #30 — `?expand=` inlined a referenced document under
  its DRAFT-prefixed `_id` (`drafts.<id>`) even when that document is PUBLISHED.

  The symptom was SILENT: reference-equality filters written against the
  published id matched nothing, and no error was raised anywhere. So the
  assertion here is on the inlined `_id` ITSELF — a test that only asserts the
  reference expanded into a map stays green with the bug present.

  How a reference comes to hold `drafts.<id>` at all: a client that reads a
  document under `?perspective=drafts` and copies the `_id` it sees into a
  reference field writes the DRAFT twin's id. That is a legal stored value —
  `Expand` resolved it literally, so the published twin was never consulted.

  NEGATIVE ARM: a genuine draft (a document that has never been published) must
  STILL expand as a draft. Rewriting draft identity in draft context would trade
  one silent mismatch for another.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}

  @dataset "expand_pubid_ds"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "author", "type" => "reference", "refType" => "author"}
          ]
        },
        @dataset
      )

    # PUBLISHED author. Both `au_pub` and `drafts.au_pub` rows exist after this.
    {:ok, _} = Content.create_document("author", %{"_id" => "au_pub", "title" => "Ada"}, @dataset)
    {:ok, _} = Content.publish_document("au_pub", "author", @dataset)

    # GENUINE draft author — never published, so only `drafts.au_draft` exists.
    {:ok, _} =
      Content.create_document("author", %{"_id" => "au_draft", "title" => "Bo"}, @dataset)

    # The post stores the DRAFT-prefixed id of a PUBLISHED author.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "po_pub", "title" => "Alpha", "author" => "drafts.au_pub"},
        @dataset
      )

    {:ok, _} = Content.publish_document("po_pub", "post", @dataset)

    # PUBLISHED author that ALSO carries a live draft edit — publish deletes the
    # draft, so a second `create_document` re-creates `drafts.au_both` beside the
    # published `au_both`. This is the state the field report describes: the
    # document IS published, and the reference spells its draft twin.
    {:ok, _} =
      Content.create_document("author", %{"_id" => "au_both", "title" => "Cy"}, @dataset)

    {:ok, _} = Content.publish_document("au_both", "author", @dataset)

    {:ok, _} =
      Content.create_document("author", %{"_id" => "au_both", "title" => "Cy edited"}, @dataset)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "po_both", "title" => "Gamma", "author" => "drafts.au_both"},
        @dataset
      )

    {:ok, _} = Content.publish_document("po_both", "post", @dataset)

    # The post that references the genuine draft — the negative arm.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "po_draft", "title" => "Beta", "author" => "drafts.au_draft"},
        @dataset
      )

    raw = "expand-pubid-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "expand pubid token", @dataset, ["read", "write"])

    {:ok, raw: raw}
  end

  defp authed(conn, raw), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> raw)

  test "published context: an expanded reference carries PUBLISHED identity", %{
    conn: conn,
    raw: raw
  } do
    body =
      conn
      |> authed(raw)
      |> get(
        "/v1/data/query/#{@dataset}/post?expand=author&perspective=published&filter[title]=Alpha"
      )
      |> json_response(200)

    [doc] = body["result"]["documents"]
    author = doc["author"]

    assert is_map(author), "author should have expanded, got: #{inspect(author)}"

    # THE ASSERTION. Pre-fix this reads "drafts.au_pub" and a consumer filtering
    # `author._id == "au_pub"` silently matches nothing.
    assert author["_id"] == "au_pub",
           "expanded reference carried DRAFT identity: #{inspect(author["_id"])}"

    assert author["_draft"] == false
    assert author["_publishedId"] == "au_pub"
  end

  test "raw context: same published identity", %{conn: conn, raw: raw} do
    body =
      conn
      |> authed(raw)
      |> get("/v1/data/query/#{@dataset}/post?expand=author&perspective=raw&filter[title]=Alpha")
      |> json_response(200)

    author = body["result"]["documents"] |> hd() |> Map.get("author")

    assert author["_id"] == "au_pub",
           "expanded reference carried DRAFT identity: #{inspect(author["_id"])}"
  end

  test "published context, target has BOTH rows: the inlined _id is the PUBLISHED id",
       %{conn: conn, raw: raw} do
    body =
      conn
      |> authed(raw)
      |> get(
        "/v1/data/query/#{@dataset}/post?expand=author&perspective=published&filter[title]=Gamma"
      )
      |> json_response(200)

    author = body["result"]["documents"] |> hd() |> Map.get("author")

    assert is_map(author), "author should have expanded, got: #{inspect(author)}"

    # THE FILED SYMPTOM, literally. Pre-fix this reads "drafts.au_both" — the
    # draft row won because the reference spelled it, even though `au_both` is
    # published and is the id every consumer filters on.
    assert author["_id"] == "au_both",
           "expanded reference carried DRAFT identity: #{inspect(author["_id"])}"

    assert author["_draft"] == false
    assert author["_publishedId"] == "au_both"
  end

  test "NEGATIVE ARM: a genuine draft still expands as a draft", %{conn: conn, raw: raw} do
    body =
      conn
      |> authed(raw)
      |> get(
        "/v1/data/query/#{@dataset}/post?expand=author&perspective=drafts&filter[title]=Beta"
      )
      |> json_response(200)

    author = body["result"]["documents"] |> hd() |> Map.get("author")

    assert is_map(author), "author should have expanded, got: #{inspect(author)}"

    assert author["_id"] == "drafts.au_draft",
           "a never-published author must keep its draft identity, got: #{inspect(author["_id"])}"

    assert author["_draft"] == true
    assert author["_publishedId"] == "au_draft"
  end
end
