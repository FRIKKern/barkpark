defmodule BarkparkWeb.QueryControllerPerspectiveTest do
  @moduledoc """
  `GET /v1/data/doc/:dataset/:type/:doc_id?perspective=drafts` READ THE FLAG AND
  THREW IT AWAY (task-857259ad1e7165d2).

  `show_doc/5` did a bare exact-id `Content.get_document/4`, so a caller that
  asked for the draft got the PUBLISHED row: HTTP 200, `_draft: false`, no
  warning, no signal of any kind. The sibling `GET /v1/data/query/:ds/:type`
  honoured the same flag on the same document in the same instant — two read
  paths disagreeing about one document, and the by-id one silently answering a
  question nobody asked. Both declare an identical `perspective` flag in
  `GET /v1/capabilities` (doc.get and doc.ls/doc.query), which is what makes it
  a defect rather than a design choice.

  Two consequences were reproduced on a local instance and are both pinned here:
  a draft-only document 404s under `?perspective=drafts`, and a published
  document with a divergent draft returns the PUBLISHED body.

  SECOND DEFECT, same endpoints, lower severity: an invalid enum value was
  silently accepted. `AnonPerspective.parse/1` maps every unrecognised string to
  `:published`, so `?perspective=bogus` answered 200 over the published set —
  and on query it echoed `"perspective":"published"`, actively telling the
  caller its typo had been honoured. `/v1/data/counts` already refused this;
  these two now match it.

  MUTATION PROOF (recorded in the PR): reverting `get_document_for_perspective/5`
  to the bare `Content.get_document(doc_id, …)` reds the four drafts-perspective
  tests below with the published title in the failure message; reverting the
  `unsupported_read_perspective/1` guard reds the three refusal tests. The
  no-new-exposure tests stay green under BOTH mutations — they are there to
  prove the fix did not widen anything, not to detect the defect.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @read_token "barkpark-test-perspective-read"
  @public_read_token "barkpark-test-perspective-public"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} = Auth.create_token(@read_token, "perspective-read", @dataset, ["read", "write"])

    {:ok, _} =
      Auth.create_token(@public_read_token, "perspective-public", @dataset, ["public-read"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A document whose published row and draft row genuinely DIVERGE — published
  # says PUB_V1, the draft says DRAFT_V2. Without divergence the defect is
  # invisible: both perspectives would return the same title and a test could
  # pass over the bug.
  defp mk_divergent!(doc_id, scope) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "PUB_V1", "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "DRAFT_V2", "content" => %{}},
        @dataset,
        scope
      )

    doc_id
  end

  defp mk_draft_only!(doc_id, title, scope) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => title, "content" => %{}},
        @dataset,
        scope
      )

    doc_id
  end

  defp mk_published_only!(doc_id, scope) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "ONLY_PUBLISHED", "content" => %{}},
        @dataset,
        scope
      )

    # publish_document/4 consumes the draft row, so this document has a
    # published row and NO draft twin — the fallback case.
    {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)
    doc_id
  end

  describe "THE DEFECT: doc-get honours ?perspective=drafts" do
    test "a divergent draft is returned, not the published row", %{conn: conn, scope: scope} do
      id = mk_divergent!(uniq("persp-divergent"), scope)

      body =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "drafts"})
        |> json_response(200)

      assert body["result"]["title"] == "DRAFT_V2",
             "?perspective=drafts served the PUBLISHED row — got #{inspect(body["result"]["title"])}, " <>
               "which is the 200-with-the-wrong-data shape this row was filed for"

      assert body["result"]["_draft"] == true
    end

    test "a draft-only document resolves instead of 404ing", %{conn: conn, scope: scope} do
      id = mk_draft_only!(uniq("persp-draft-only"), "DRAFT_ONLY_TITLE", scope)

      body =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "drafts"})
        |> json_response(200)

      assert body["result"]["title"] == "DRAFT_ONLY_TITLE"
    end

    test "a published-only document FALLS BACK rather than 404ing — matching the query endpoint",
         %{conn: conn, scope: scope} do
      # The fallback is the half a naive "just prefix drafts." fix gets wrong.
      # The query endpoint's drafts perspective returns published rows where no
      # draft exists, so doc-get must not start 404ing documents that have been
      # published and have no outstanding draft.
      id = mk_published_only!(uniq("persp-pub-only"), scope)

      body =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "drafts"})
        |> json_response(200)

      assert body["result"]["title"] == "ONLY_PUBLISHED"
      assert body["result"]["_draft"] == false
    end

    test "the by-id and by-query read paths now AGREE about the same document",
         %{conn: conn, scope: scope} do
      # The original report's framing: a consumer that pages the query endpoint
      # saw the draft, a consumer that fetched by id did not. Assert the
      # agreement directly rather than each side in isolation.
      id = mk_divergent!(uniq("persp-agree"), scope)

      by_id =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "drafts"})
        |> json_response(200)
        |> get_in(["result", "title"])

      by_query =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/query/#{@dataset}/post", %{"perspective" => "drafts", "limit" => "1000"})
        |> json_response(200)
        |> Map.fetch!("result")
        |> Map.fetch!("documents")
        |> Enum.find(%{}, &(&1["_publishedId"] == id or &1["_id"] in [id, "drafts." <> id]))
        |> Map.get("title")

      assert by_id == by_query,
             "the two read paths disagree about #{id}: by-id says #{inspect(by_id)}, " <>
               "by-query says #{inspect(by_query)}"
    end
  end

  describe "published and raw keep the exact-id lookup" do
    test "the default perspective still serves the published row", %{conn: conn, scope: scope} do
      id = mk_divergent!(uniq("persp-default"), scope)

      body =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}")
        |> json_response(200)

      assert body["result"]["title"] == "PUB_V1"
    end

    test "?perspective=raw resolves the id as given, like published", %{conn: conn, scope: scope} do
      id = mk_divergent!(uniq("persp-raw"), scope)

      published =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "raw"})
        |> json_response(200)

      assert published["result"]["title"] == "PUB_V1"

      # …and the explicit drafts.<id> spelling still names the draft row under
      # raw, which is the documented bare-`bp doc get` asymmetry and NOT the
      # defect this row is about.
      draft =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/drafts.#{id}", %{"perspective" => "raw"})
        |> json_response(200)

      assert draft["result"]["title"] == "DRAFT_V2"
    end
  end

  describe "NO NEW EXPOSURE (green under both mutations — a guard, not a detector)" do
    test "an anonymous caller asking for drafts still gets the published row", %{
      conn: conn,
      scope: scope
    } do
      id = mk_divergent!(uniq("persp-anon"), scope)

      body =
        conn
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "drafts"})
        |> json_response(200)

      assert body["result"]["title"] == "PUB_V1",
             "AnonPerspective.resolve/2 must pin an anonymous caller to :published " <>
               "BEFORE the new draft-preferring lookup runs"
    end

    test "a public-read site token asking for drafts is REFUSED before this code runs", %{
      conn: conn,
      scope: scope
    } do
      # Measured, not assumed: BarkparkWeb.Plugs.PublicRead already answers
      # 403 "perspective not allowed" (public_read.ex:141) to a browser-shipped
      # site credential that names a non-published perspective. It never reaches
      # get_document_for_perspective/5 at all. Pinned so a later refactor that
      # moves the perspective decision earlier cannot quietly convert this 403
      # into a served draft.
      id = mk_divergent!(uniq("persp-publicread"), scope)

      resp =
        conn
        |> bearer(@public_read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "drafts"})

      assert resp.status == 403
      refute resp.resp_body =~ "DRAFT_V2"
    end

    test "an anonymous caller still cannot name a drafts.<id> directly", %{
      conn: conn,
      scope: scope
    } do
      id = mk_divergent!(uniq("persp-anon-prefixed"), scope)

      resp = get(conn, "/v1/data/doc/#{@dataset}/post/drafts.#{id}", %{"perspective" => "drafts"})
      assert resp.status == 404
    end
  end

  describe "SECOND DEFECT: an unsupported ?perspective is refused, not silently downgraded" do
    test "doc-get answers 400 naming the parameter and the supported values", %{
      conn: conn,
      scope: scope
    } do
      id = mk_divergent!(uniq("persp-bogus-doc"), scope)

      body =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "zzzbogus"})
        |> json_response(400)

      assert body["error"]["details"]["parameter"] == "perspective"
      assert body["error"]["details"]["received"] == "zzzbogus"
      assert body["error"]["details"]["supported"] == ["published", "drafts", "raw"]
      refute body["result"], "a refused request must not also carry a document"
    end

    test "query answers 400 instead of echoing perspective:published over a typo", %{conn: conn} do
      body =
        conn
        |> bearer(@read_token)
        |> get("/v1/data/query/#{@dataset}/post", %{"perspective" => "zzzbogus"})
        |> json_response(400)

      assert body["error"]["details"]["received"] == "zzzbogus"

      refute get_in(body, ["result", "perspective"]) == "published",
             "the old behaviour told the caller its typo had been honoured"
    end

    test "an ANONYMOUS caller on a private type gets 404, not the 400 — the refusal is never an existence probe",
         %{conn: conn, scope: scope} do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "secret", "title" => "Secret", "visibility" => "private", "fields" => []},
          @dataset,
          scope
        )

      resp = get(conn, "/v1/data/doc/#{@dataset}/secret/whatever", %{"perspective" => "zzzbogus"})

      assert resp.status == 404,
             "the existence-hiding 404 must beat the perspective 400, or the refusal " <>
               "distinguishes a private type from a nonexistent one"
    end

    test "all three supported values still answer 200", %{conn: conn, scope: scope} do
      id = mk_divergent!(uniq("persp-enum"), scope)

      for p <- ["published", "drafts", "raw"] do
        resp =
          conn
          |> bearer(@read_token)
          |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => p})

        assert resp.status == 200, "?perspective=#{p} should be honoured, got #{resp.status}"
      end
    end
  end
end
