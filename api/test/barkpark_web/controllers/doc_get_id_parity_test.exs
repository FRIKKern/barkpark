defmodule BarkparkWeb.DocGetIdParityTest do
  @moduledoc """
  ONE identifier for read and write across a document's whole life
  (task-aa22f3bd921e1c56).

  `bp doc create <type>` hands back a document carrying both `_id`
  ("drafts.post-XXXX") and `_publishedId` ("post-XXXX"). Every write verb
  resolves the bare published id to the draft — `patch`, `publish`,
  `discardDraft` and `delete` all reach an unpublished document by
  `post-XXXX`, through `Mutations.get_patch_base/4` and
  `Content.publish_document/4`'s own `drafts.` fallback. `doc get` did not
  agree: under `?perspective=raw` it ran a bare exact-id lookup, so the
  natural read-back after a create — take the id the create just handed you
  and get it — answered `not_found` for a document that exists.

  That is the read-side twin of "a 500 can hide a write that landed": a 200
  and a valid id followed by a not_found, from which an operator or an agent
  reasonably concludes the create failed and retries, producing duplicates.

  WHAT THE FILING GOT WRONG, measured on origin/main before any change here:
  `?perspective=drafts` ALREADY resolved the bare id. Task-857259ad1e7165d2
  taught `get_document_for_perspective/5` to prefer the draft twin under
  `:drafts` and fall back to the published row. So the first criterion was
  already met and the defect was narrower than the reported matrix: `raw`
  alone, plus the absence of any test driving one id through all five verbs.
  The tests below are written to distinguish those two halves rather than to
  report one verdict for both.

  `published` is deliberately NOT changed. Publishing is the act of making a
  document public, so the published perspective answering `not_found` for an
  unpublished document is the correct answer, not the defect.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @token "barkpark-test-doc-get-parity"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} = Auth.create_token(@token, "doc-get-parity", @dataset, ["read", "write"])

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

  defp bearer(conn, token \\ @token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Create through the SAME door an operator uses — POST /v1/data/mutate — so
  # the id under test is the one the API itself handed back, not one a fixture
  # chose. Returns the bare published id, which is what `bp doc create` prints
  # as `_publishedId` and what every write verb below is given.
  defp create!(conn, doc_id, title) do
    body =
      conn
      |> bearer()
      |> post("/v1/data/mutate/#{@dataset}", %{
        "mutations" => [
          %{"create" => %{"_id" => doc_id, "_type" => "post", "title" => title, "content" => %{}}}
        ]
      })
      |> json_response(200)

    [result] = body["results"]

    assert result["id"] == "drafts." <> doc_id,
           "the create stored the draft twin, so its id is the drafts. spelling — " <>
             "got #{inspect(result["id"])}"

    doc_id
  end

  defp mutate(conn, mutation) do
    conn
    |> bearer()
    |> post("/v1/data/mutate/#{@dataset}", %{"mutations" => [mutation]})
  end

  defp doc_get(conn, doc_id, perspective) do
    conn
    |> bearer()
    |> get("/v1/data/doc/#{@dataset}/post/#{doc_id}", %{"perspective" => perspective})
  end

  describe "doc get resolves the bare published id on an unpublished document" do
    test "?perspective=drafts returns the draft (already true on main — the control)",
         %{conn: conn} do
      id = create!(conn, uniq("parity-drafts"), "DRAFT_TITLE")

      body = conn |> doc_get(id, "drafts") |> json_response(200)

      assert body["result"]["title"] == "DRAFT_TITLE"
      assert body["result"]["_draft"] == true
    end

    test "?perspective=raw returns the draft", %{conn: conn} do
      id = create!(conn, uniq("parity-raw"), "RAW_TITLE")

      resp = doc_get(conn, id, "raw")

      assert resp.status == 200,
             "doc get raw answered #{resp.status} for #{id}, a document that exists and that " <>
               "doc patch/publish/discardDraft/delete all reach by this exact id"

      body = json_response(resp, 200)
      assert body["result"]["title"] == "RAW_TITLE"
      assert body["result"]["_draft"] == true
    end

    test "?perspective=published still answers not_found — unpublished means not public",
         %{conn: conn} do
      id = create!(conn, uniq("parity-published"), "NOT_PUBLIC")

      assert doc_get(conn, id, "published").status == 404
    end
  end

  describe "raw keeps naming the exact row when both spellings exist" do
    test "a document with a divergent draft answers with the PUBLISHED row under raw",
         %{conn: conn} do
      # The half a naive "just prefix drafts." fix gets wrong. raw means no
      # perspective filter: the id names a row, and when that row exists it is
      # the answer. The draft fallback is reached only when the bare id names
      # nothing — which is the unpublished case above.
      id = create!(conn, uniq("parity-divergent"), "PUB_V1")
      assert mutate(conn, %{"publish" => %{"id" => id, "type" => "post"}}).status == 200
      _ = create!(conn, id, "DRAFT_V2")

      body = conn |> doc_get(id, "raw") |> json_response(200)

      assert body["result"]["title"] == "PUB_V1"
      assert body["result"]["_draft"] == false

      # …and the explicit drafts.<id> spelling still names the draft row.
      draft = conn |> doc_get("drafts." <> id, "raw") |> json_response(200)
      assert draft["result"]["title"] == "DRAFT_V2"
    end
  end

  describe "one identifier across all five verbs" do
    test "create -> get -> patch -> get -> publish -> get -> delete, all on the bare id",
         %{conn: conn} do
      id = create!(conn, uniq("parity-lifecycle"), "V0")

      # GET — the read-back immediately after the create. This is the step the
      # filing reproduced as not_found.
      for perspective <- ["drafts", "raw"] do
        body = conn |> doc_get(id, perspective) |> json_response(200)

        assert body["result"]["title"] == "V0",
               "doc get #{perspective} did not resolve #{id} straight after the create"
      end

      # PATCH — the bare id, on a document that exists only as drafts.<id>.
      assert mutate(conn, %{
               "patch" => %{"id" => id, "type" => "post", "set" => %{"title" => "V1"}}
             }).status == 200

      assert conn |> doc_get(id, "drafts") |> json_response(200) |> get_in(["result", "title"]) ==
               "V1"

      assert conn |> doc_get(id, "raw") |> json_response(200) |> get_in(["result", "title"]) ==
               "V1"

      # PUBLISH — same bare id. Afterwards all three perspectives answer, which
      # is the half of the lifecycle that already worked.
      assert mutate(conn, %{"publish" => %{"id" => id, "type" => "post"}}).status == 200

      for perspective <- ["published", "drafts", "raw"] do
        assert conn
               |> doc_get(id, perspective)
               |> json_response(200)
               |> get_in(["result", "title"]) ==
                 "V1",
               "doc get #{perspective} lost #{id} after publish"
      end

      # DELETE — same bare id, and the read-back now legitimately reports gone.
      assert mutate(conn, %{"delete" => %{"id" => id, "type" => "post"}}).status == 200

      for perspective <- ["published", "drafts", "raw"] do
        assert doc_get(conn, id, perspective).status == 404
      end
    end

    test "discardDraft takes the same bare id, and the read-back agrees with it",
         %{conn: conn} do
      # discardDraft is exclusive with publish on one document, so it gets its
      # own run rather than being wedged into the sequence above.
      id = create!(conn, uniq("parity-discard"), "DISCARD_ME")

      assert conn |> doc_get(id, "raw") |> json_response(200) |> get_in(["result", "title"]) ==
               "DISCARD_ME"

      assert mutate(conn, %{"discardDraft" => %{"id" => id, "type" => "post"}}).status == 200

      for perspective <- ["published", "drafts", "raw"] do
        assert doc_get(conn, id, perspective).status == 404,
               "the draft was discarded, so #{perspective} must report it gone"
      end
    end
  end

  describe "no new exposure" do
    test "an anonymous caller asking for raw does not get the draft", %{conn: conn} do
      # AnonPerspective.resolve/2 pins an anonymous caller to :published before
      # the fallback runs. Green under the mutation below — a guard, not a
      # detector.
      id = create!(conn, uniq("parity-anon"), "ANON_HIDDEN")

      resp = get(conn, "/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "raw"})

      assert resp.status == 404
      refute resp.resp_body =~ "ANON_HIDDEN"
    end
  end
end
