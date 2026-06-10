defmodule BarkparkWeb.Contract.AnonymousPerspectiveTest do
  @moduledoc """
  An ANONYMOUS (tokenless) caller is pinned to the published perspective on
  every read shape — regression for the live 2026-06-10 finding that
  `?perspective=drafts|raw` on a public-visibility schema returned every
  draft to a caller with no credentials at all.

  The invariant already existed in three sibling forms — the PublicRead plug
  403s drafts/raw for `public-read` TOKENS, the read-share path pins share
  readers to published, and preview access requires a signed preview token —
  but the plain tokenless read fell through all three. Publish is the act of
  making content public; a `drafts.` row is unpublished by definition.

  A valid token keeps full perspective access (covered here), an `:edit`
  share keeps draft visibility (covered in shared_edit_test.exs), and
  preview tokens keep their forced drafts view (preview_token_test.exs).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @dataset "test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    # One published doc and one draft-only doc: the draft must be invisible
    # to every anonymous read shape, visible to the authed ones.
    {:ok, _} = Content.create_document("post", %{"_id" => "pub1", "title" => "Public"}, @dataset)
    {:ok, _} = Content.publish_document("pub1", "post", @dataset)

    {:ok, _} =
      Content.create_document("post", %{"_id" => "dr1", "title" => "Draft Only"}, @dataset)

    raw = "anon-persp-tok-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "anon-persp test", @dataset, ["read", "write"])

    {:ok, token: raw}
  end

  defp ids(body), do: Enum.map(body["result"]["documents"], & &1["_id"])

  test "anonymous ?perspective=drafts is pinned to published", %{conn: conn} do
    body =
      conn
      |> get("/v1/data/query/#{@dataset}/post?perspective=drafts")
      |> json_response(200)

    assert body["result"]["perspective"] == "published"
    assert "pub1" in ids(body)
    refute "drafts.dr1" in ids(body)
  end

  test "anonymous ?perspective=raw is pinned to published", %{conn: conn} do
    body =
      conn
      |> get("/v1/data/query/#{@dataset}/post?perspective=raw")
      |> json_response(200)

    assert body["result"]["perspective"] == "published"
    refute Enum.any?(ids(body), &String.starts_with?(&1, "drafts."))
  end

  test "anonymous GET doc by drafts.<id> is 404", %{conn: conn} do
    conn
    |> get("/v1/data/doc/#{@dataset}/post/drafts.dr1")
    |> json_response(404)
  end

  test "a valid token keeps full perspective access", %{conn: conn, token: token} do
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/v1/data/query/#{@dataset}/post?perspective=drafts")
      |> json_response(200)

    assert body["result"]["perspective"] == "drafts"
    assert "drafts.dr1" in ids(body)

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/v1/data/doc/#{@dataset}/post/drafts.dr1")
    |> json_response(200)
  end
end
