defmodule BarkparkWeb.Integration.PreviewTokenPerspectiveTest do
  @moduledoc """
  task-500b916ecdb0d1c0 — a Preview JWT read ignored `?perspective=` entirely
  and always answered drafts, so Presentation's Published-view switch (J63,
  Sanity's perspective switch) could never show the published page through
  the SAME studio-minted scoped token its draft preview already uses.

  `BarkparkWeb.Plugs.PreviewToken` unconditionally assigned
  `forced_perspective: "drafts"`; `AnonPerspective.resolve/2` reads that
  assign FIRST and never looks at the `?perspective=` param once it is set.
  Drafts stays the default (every existing integration that never asks is
  unaffected); an explicit `published` or `raw` now rides through.

  `async: false` — `Application.put_env(:barkpark, :preview, …)` is global.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, PreviewToken}

  @secret "test-preview-secret-perspective-1234567890"
  @dataset "production"

  setup do
    prior = Application.get_env(:barkpark, :preview)

    Application.put_env(:barkpark, :preview,
      secret: @secret,
      ttl_seconds: 600,
      issuer: "barkpark"
    )

    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    doc_id = "ptp-#{System.unique_integer([:positive])}"

    {:ok, _} = Content.create_document("post", %{"_id" => doc_id, "title" => "PUB"}, @dataset)
    {:ok, _} = Content.publish_document(doc_id, "post", @dataset)
    # Edit the draft AFTER publishing, so drafts and published genuinely
    # diverge -- the property under test needs a visible difference.
    {:ok, _} =
      Content.create_document("post", %{"_id" => doc_id, "title" => "DRAFT"}, @dataset)

    %{doc_id: doc_id}
  end

  defp preview(conn, jwt), do: put_req_header(conn, "authorization", "Preview " <> jwt)

  defp mint!(multi_use \\ true) do
    {jwt, _claims} =
      PreviewToken.sign(%{dataset: @dataset, multi_use: multi_use}, @secret)

    jwt
  end

  test "no ?perspective= still answers drafts, unchanged", %{conn: conn, doc_id: doc_id} do
    jwt = mint!()

    body =
      conn
      |> preview(jwt)
      |> get("/v1/preview/doc/#{@dataset}/post/#{doc_id}")
      |> json_response(200)

    assert body["result"]["title"] == "DRAFT"
  end

  test "?perspective=drafts is unchanged too", %{conn: conn, doc_id: doc_id} do
    jwt = mint!()

    body =
      conn
      |> preview(jwt)
      |> get("/v1/preview/doc/#{@dataset}/post/#{doc_id}", %{"perspective" => "drafts"})
      |> json_response(200)

    assert body["result"]["title"] == "DRAFT"
  end

  test "?perspective=published now answers the published row, not the draft", %{
    conn: conn,
    doc_id: doc_id
  } do
    jwt = mint!()

    body =
      conn
      |> preview(jwt)
      |> get("/v1/preview/doc/#{@dataset}/post/#{doc_id}", %{"perspective" => "published"})
      |> json_response(200)

    assert body["result"]["title"] == "PUB"
  end

  test "?perspective=raw answers too (bare-id-first, same precedence a Bearer caller gets)", %{
    conn: conn,
    doc_id: doc_id
  } do
    jwt = mint!()

    body =
      conn
      |> preview(jwt)
      |> get("/v1/preview/doc/#{@dataset}/post/#{doc_id}", %{"perspective" => "raw"})
      |> json_response(200)

    # `:raw` tries the bare id BEFORE the `drafts.` twin (QueryController.
    # get_document_for_perspective/5) -- the bare id is where publish_document
    # writes, so this doc_id's bare row is the PUBLISHED one.
    assert body["result"]["title"] == "PUB"
  end
end
