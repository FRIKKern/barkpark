defmodule BarkparkWeb.GlobalSchemaEnvelopeSurfacesTest do
  @moduledoc """
  The GLOBAL-schema redaction fallback on the Envelope render surfaces that
  never had it (task-3d433b8f497738f9 — the twin of the legacy/query-path fix
  pinned by `envelope_global_schema_redaction_test.exs`).

  THE SHAPE OF THE HOLE. `Content.get_schema/3` with a binary `:workspace_id`
  filters `where workspace_id == ^ws`, so a schema declared GLOBALLY
  (`workspace_id: nil`) never matches a document that lives in a workspace.
  `Envelope` is fail-OPEN on a nil schema (an undeclared field is public), so a
  render site that did a SINGLE scoped lookup and `_ -> nil` on the miss handed
  every `private` field of that type to whoever was reading.

  Each test below drives one of the surfaces the row's census named, against a
  GLOBAL schema whose `private` field carries a value that must never appear:

    1. the public paper reader     — `Content.Papers.reader_source/3`   (D1)
    2. `GET /s/:token`             — ShareLinkController                (D4)
    3. `GET .../v1/media/:ds/:id`  — Media.Delivery.AssetResponse        (D3)
    4. `GET .../v1/data/revision/` — HistoryController.show             (D6)
    5. `GET .../v1/data/search/`   — SearchController schema_resolver   (D5)

  ISOLATION ON A FLEET-SHARED DATABASE. Every schema, type, dataset, workspace
  and token name here is unique to this run, and the dataset is one no other
  agent can own. That matters for correctness, not just hygiene: the helper's
  fallback re-queries WITHOUT the tenant keys, so a same-named schema seeded by
  another workspace in a SHARED dataset could win the `limit(1)` and be
  (correctly) rejected as a foreign tenant's row — turning a real fix into a
  flaky red. A private dataset makes the global row the only candidate.

  WHY THE PAPER READER IS A FUNCTION-LEVEL TEST. `live "/papers/:slug"` resolves
  only dataset `production` in the seeded Default workspace, and `paper` is a
  plugin-declared type that is bootstrapped INTO that workspace — so a conn test
  there could not isolate the global row from the seeded scoped one on a shared
  database. `reader_source/3` is the function the LiveView calls, and it pins
  `CallerContext.anonymous()` internally, so calling it IS the anonymous read.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Sharing.{Links, ShareLink}
  alias Barkpark.Tenancy

  @uniq System.unique_integer([:positive])
  @ds "gsfds#{@uniq}"
  @gtype "gsfglobal#{@uniq}"
  @stype "gsfscoped#{@uniq}"
  @reader_token "gsf-reader-#{@uniq}"

  # The values that must never reach a reader. Each is distinctive enough that a
  # red names the leak rather than just a missing key.
  @global_secret "GSF-GLOBAL-SSN-#{@uniq}"
  @scoped_secret "GSF-SCOPED-SSN-#{@uniq}"
  @rights_secret "GSF-RIGHTS-#{@uniq}"
  @prose_secret "GSF-PROSE-#{@uniq}"
  @needle "zarquonaut#{@uniq}"

  setup do
    ws = create_workspace!("gsf-ws-#{@uniq}")
    proj = create_project!(ws, "gsf-proj-#{@uniq}")
    scope = [workspace_id: ws.id, project_id: proj.id]

    # THE DATASET ENTITY IS LOAD-BEARING for the media read: with a NULL
    # dataset_id the blob query matches nothing and every media assertion greens
    # against an empty response.
    {:ok, _dataset} = Tenancy.get_or_create_dataset(proj, @ds)

    # ── The GLOBAL schemas (workspace_id: nil) ──────────────────────────────
    # `upsert_schema` stamps tenant scope via `Content.put_scope_attrs/2`, so a
    # nil-workspace row is only reachable by a direct insert — the sanctioned
    # fixture for a global schema (same as envelope_global_schema_redaction_test).
    global_schema!(@gtype, [
      %{"name" => "name", "type" => "string"},
      %{"name" => "ssn", "type" => "string", "private" => true, "encrypted" => false}
    ])

    global_schema!("mediaAsset", [
      %{"name" => "mediaFileId", "type" => "string"},
      %{"name" => "rightsNote", "type" => "string", "private" => true, "encrypted" => false}
    ])

    global_schema!("paper", [
      %{"name" => "blocks", "type" => "array", "private" => true, "encrypted" => false}
    ])

    # ── The workspace-SCOPED sibling ────────────────────────────────────────
    # Resolves on the first (scoped) step, so it must still redact after the
    # change — the non-regression half of the search assertion.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @stype,
          "title" => "Scoped Sibling",
          "visibility" => "public",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "ssn", "type" => "string", "private" => true}
          ]
        },
        @ds,
        scope
      )

    # The 5-arity form homes the token in THIS workspace and writes the
    # membership itself, so a second explicit write would hit the principal
    # unique index.
    {:ok, _token} = Auth.create_token(@reader_token, "gsf reader", @ds, ["read"], ws.id)

    %{ws: ws, proj: proj, scope: scope}
  end

  # ── 1. the public paper reader (D1 — content/papers.ex reader_source/3) ────

  test "the anonymous paper reader redacts a GLOBALLY-declared private blocks field",
       %{scope: scope} do
    {:ok, seed} =
      Content.create_document(
        @gtype,
        %{"doc_id" => "gsf-paper-seed-#{@uniq}", "title" => "Seed"},
        @ds,
        scope
      )

    blocks = [%{"id" => "b1", "type" => "paragraph", "text" => @prose_secret}]

    body_html =
      Barkpark.PortableDoc.Render.render_blocks(
        blocks,
        Barkpark.Content.Labels.paper_render_opts(@ds, nil, scope)
      )

    paper = %{
      seed
      | type: "paper",
        content: %{"body" => %{"blocks" => blocks}, "body_html" => body_html}
    }

    # The paper lives in a workspace; the only "paper" schema in this dataset is
    # the GLOBAL one, whose `blocks` field is private. The anonymous reader must
    # therefore find NO servable source — never the prose, and never the derived
    # body_html cache of the same prose.
    source = Content.Papers.reader_source(paper, @ds, [])

    assert match?({:error, :redacted_source}, source),
           "the global schema's private `blocks` leaked #{@prose_secret} to the anonymous paper reader (got #{inspect(source)})"
  end

  # ── 2. GET /s/:token (D4 — share_link_controller.ex) ───────────────────────

  test "an anonymous share-link read redacts a GLOBALLY-declared private field", %{
    ws: ws,
    proj: proj,
    scope: scope
  } do
    doc_id = "gsf-share-#{@uniq}"
    publish_doc!(@gtype, doc_id, "Share Target", @global_secret, scope)

    raw = "gsfshare#{@uniq}" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    Repo.insert!(%ShareLink{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: @ds,
      kind: "doc",
      ref_type: @gtype,
      ref_id: doc_id,
      access: "read",
      # Only the digest — the plaintext column was retired
      # (arpss-w8-bl-share-link-raw-token-at-rest); `resolve/1` matches the hash.
      token_hash: Links.hash_token(raw)
    })

    body = build_conn() |> get("/s/#{raw}") |> json_response(200)

    # Non-vacuity: the public field proves the envelope really rendered THIS doc.
    assert body["name"] == "public-#{@uniq}"
    refute Map.has_key?(body, "ssn"), "GET /s/:token leaked #{@global_secret}"
    refute inspect(body) =~ @global_secret
  end

  # ── 3. GET /v1/media/:dataset/:id (D3 — media/delivery/asset_response.ex) ──

  # The flat spelling, read ANONYMOUSLY. The scoped twin (`/w/:ws/p/:proj/...`)
  # is membership-gated, so an anonymous caller is refused there before the
  # renderer runs — which would test the pipeline, not the redaction. The flat
  # route resolves the seeded Default workspace via AssignDefaultScope, so the
  # asset lives there; `asset_schema/2` still scopes by the DOC's own
  # workspace_id (a binary), so the global row is just as unreachable without
  # the fallback.
  test "an anonymous media asset read redacts a GLOBALLY-declared private field" do
    {default_ws, default_proj} = ensure_default_scope!()
    scope = [workspace_id: default_ws.id, project_id: default_proj.id]
    {:ok, dataset} = Tenancy.get_or_create_dataset(default_proj, @ds)

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "gsf-#{@uniq}.png",
        original_name: "gsf-#{@uniq}-original.png",
        path: "test/gsf/#{@uniq}.png",
        mime_type: "image/png",
        size: 42,
        dataset: @ds,
        dataset_id: dataset.id,
        workspace_id: default_ws.id,
        project_id: default_proj.id
      })
      |> Repo.insert!()

    asset_doc_id = "gsf-asset-#{@uniq}"

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "_id" => asset_doc_id,
          "title" => "GSF Asset",
          "mediaFileId" => file.id,
          "rightsNote" => @rights_secret
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(asset_doc_id, "mediaAsset", @ds, scope)

    result =
      build_conn()
      |> get("/v1/media/#{@ds}/#{file.id}")
      |> json_response(200)
      |> Map.fetch!("result")

    asset = result["asset"]

    # Non-vacuity: the asset envelope really rendered (a nil `asset` would make
    # the refutes below trivially true).
    assert is_map(asset), "no asset envelope rendered — the redaction assertion would be vacuous"
    assert asset["_id"] == asset_doc_id

    refute Map.has_key?(asset, "rightsNote"),
           "GET /v1/media/:dataset/:id leaked #{@rights_secret}"

    refute inspect(result) =~ @rights_secret
  end

  # ── 4. GET /v1/data/revision/:dataset/:id (D6 — history_controller.ex:28) ──

  test "a revision read with a read token redacts a GLOBALLY-declared private field", %{
    ws: ws,
    proj: proj,
    scope: scope
  } do
    doc_id = "gsf-rev-#{@uniq}"
    publish_doc!(@gtype, doc_id, "Revision Target", @global_secret, scope)

    # A revision snapshot is a side effect of a mutation — there is no fixture.
    {:ok, _} =
      Content.apply_mutations(
        [%{"patch" => %{"id" => doc_id, "type" => @gtype, "set" => %{"title" => "V2"}}}],
        @ds,
        scope
      )

    [%{id: rev_id} | _] = Content.list_revisions(doc_id, @gtype, @ds, scope)

    body =
      build_conn()
      |> bearer(@reader_token)
      |> get(scoped(ws, proj, "/v1/data/revision/#{@ds}/#{rev_id}"))
      |> json_response(200)

    content = body["revision"]["content"] || %{}

    # Non-vacuity: the snapshot really carried this document's fields.
    assert content["name"] == "public-#{@uniq}"

    refute Map.has_key?(content, "ssn"),
           "GET /v1/data/revision/:dataset/:id leaked #{@global_secret}"

    refute inspect(body) =~ @global_secret
  end

  # ── 5. GET /v1/data/search/:dataset (D5 — search_controller.ex resolver) ───

  test "multi-type search redacts the GLOBAL type and keeps redacting its scoped sibling", %{
    ws: ws,
    proj: proj,
    scope: scope
  } do
    publish_doc!(@gtype, "gsf-search-g-#{@uniq}", "#{@needle} global", @global_secret, scope)
    publish_doc!(@stype, "gsf-search-s-#{@uniq}", "#{@needle} scoped", @scoped_secret, scope)

    body =
      build_conn()
      |> bearer(@reader_token)
      |> get(scoped(ws, proj, "/v1/data/search/#{@ds}"), q: @needle)
      |> json_response(200)

    documents = body["documents"] || []
    by_type = Map.new(documents, &{&1["_type"], &1})

    # Non-vacuity: BOTH types are in this result set, so both refutes below are
    # about a document that actually rendered.
    assert Map.has_key?(by_type, @gtype), "the global-schema type is missing from the result set"
    assert Map.has_key?(by_type, @stype), "the scoped sibling type is missing from the result set"

    refute Map.has_key?(by_type[@gtype], "ssn"),
           "search leaked the GLOBAL type's private field: #{@global_secret}"

    # The sibling resolves on the FIRST (scoped) step — it must keep redacting.
    refute Map.has_key?(by_type[@stype], "ssn"),
           "search stopped redacting the workspace-SCOPED sibling: #{@scoped_secret}"

    refute inspect(documents) =~ @global_secret
    refute inspect(documents) =~ @scoped_secret
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp global_schema!(name, fields) do
    Repo.insert!(%SchemaDefinition{
      name: name,
      title: "Global #{name}",
      visibility: "public",
      dataset: @ds,
      workspace_id: nil,
      project_id: nil,
      dataset_id: nil,
      fields: fields
    })
  end

  defp publish_doc!(type, doc_id, title, secret, scope) do
    {:ok, _} =
      Content.create_document(
        type,
        %{
          "_id" => doc_id,
          "title" => title,
          "name" => "public-#{@uniq}",
          "ssn" => secret
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, type, @ds, scope)
  end

  defp scoped(ws, proj, suffix), do: "/w/#{ws.slug}/p/#{proj.slug}#{suffix}"

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
end
