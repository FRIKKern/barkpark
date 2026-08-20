defmodule Barkpark.Search.LightSelectTest do
  @moduledoc """
  Protective test for the retrieval column projection (search-latency slice a):
  when a `?fields=` caller's allowlist needs none of the heavy `content` blobs,
  `DocumentsRetriever` SELECTs a light row (heavy keys stripped at the DB) —
  the DB-level twin of `Content.Envelope.project/2`.

  The invariant it locks: the rendered+projected envelope is BYTE-IDENTICAL
  whether the retriever returned a full `%Document{}` or the light map. Without
  the fix this file's `assert light == full` still passes (the projection is
  additive); it FAILS if the light-select ever drops a scalar the allowlist
  keeps, ships the wrong shape (e.g. an undecoded jsonb string for `content`),
  or starves paper block-promotion — the three ways slice (a) could regress.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Envelope
  alias Barkpark.Search.DocumentsRetriever

  @ds "light-select-test"

  # A ~40KB body_html — the exact blob slice (a) drops. If it ever survived the
  # light path into the returned content map, the `refute` below catches it.
  @heavy_html String.duplicate("<p>lorem ipsum body payload</p>", 1200)

  defp setup_scope do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    # W10 schema-visibility gate: anonymous searches (no caller_context) are
    # restricted to PUBLIC schema types — seed the types under test as public
    # so the light/full select parity runs over admitted types.
    for type <- ~w(post paper) do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public"},
          @ds,
          scope
        )
    end

    scope
  end

  defp uid, do: "doc-#{System.unique_integer([:positive])}"

  # Render exactly as SearchController does: multi-type render (nil schema
  # resolver — the anonymous finder case) then project to the allowlist.
  defp render_project(hits, fields) do
    hits
    |> Envelope.render_many_by_type(fn _type -> nil end, nil)
    |> Envelope.project(fields)
  end

  test "light-select envelope is byte-identical to the full-struct envelope" do
    scope = setup_scope()
    id = uid()

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "doc_id" => id,
          "title" => "Deploy Runbook",
          "content" => %{
            "description" => "How to deploy the box",
            "slug" => "deploy-runbook",
            "author" => "Knut",
            "body_html" => @heavy_html
          }
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(id, "post", @ds, scope)

    fields = "title,description,slug,author"

    # Full path (no :fields) — the returned struct carries the heavy body_html.
    {full_hits, _t, _m} = Content.search_documents("", @ds, scope)
    # Light path — same query, retriever drops the heavy blob at the DB.
    {light_hits, _t, _m} = Content.search_documents("", @ds, scope ++ [fields: fields])

    full = render_project(full_hits, fields)
    light = render_project(light_hits, fields)

    assert full == light
    assert [%{"title" => "Deploy Runbook", "slug" => "deploy-runbook"}] = light

    # The light hit's content genuinely lost the heavy blob (proves the DB, not
    # just Envelope.project, did the dropping — the whole point of the slice).
    light_hit = Enum.find(light_hits, &(&1.doc_id == id))
    assert light_hit.content["description"] == "How to deploy the box"
    refute Map.has_key?(light_hit.content, "body_html")

    # And the full hit still carries it (control — the corpus really has it).
    full_hit = Enum.find(full_hits, &(&1.doc_id == id))
    assert full_hit.content["body_html"] == @heavy_html
  end

  test "paper block-promotion is identical across full and light paths" do
    scope = setup_scope()
    id = uid()

    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => id,
          "title" => "Deploy Paper",
          "content" => %{
            "description" => "A paper description long enough to pass the wall",
            "slug" => "deploy-paper",
            "body" => "# Heading\n\nSome body text that becomes blocks."
          }
        },
        @ds,
        scope
      )

    # Perspective :raw so the unpublished paper is visible without tripping the
    # publish-time authoring wall — block promotion in Envelope.render is
    # publish-independent, which is all this parity test exercises.
    persp = [perspective: :raw]

    # Allowlist WITHOUT blocks/body: both paths must render the same scalars and
    # neither must leak promoted blocks (project drops them either way).
    fields = "title,description,slug"
    {full_hits, _t, _m} = Content.search_documents("", @ds, scope ++ persp)
    {light_hits, _t, _m} = Content.search_documents("", @ds, scope ++ persp ++ [fields: fields])

    assert render_project(full_hits, fields) == render_project(light_hits, fields)
  end

  test "a fields=blocks caller declines the light-select and keeps promotion" do
    scope = setup_scope()
    id = uid()

    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => id,
          "title" => "Blocks Wanted",
          "content" => %{
            "description" => "A blocks paper description passing the authoring wall",
            "body" => "# Title\n\nBody paragraph."
          }
        },
        @ds,
        scope
      )

    # blocks is a heavy key → light-select MUST decline → full struct → render
    # promotes blocks from body → project keeps them. Perspective :raw to see
    # the unpublished paper without the publish-time authoring wall.
    fields = "title,blocks"

    {hits, _t, _m} =
      Content.search_documents("", @ds, scope ++ [perspective: :raw, fields: fields])

    [env] = render_project(hits, fields)

    assert is_list(env["blocks"])
    assert env["blocks"] != []
  end

  test "direct retriever light-select returns map-shaped hits Envelope can render" do
    scope = setup_scope()
    id = uid()

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => id, "title" => "Direct", "content" => %{"slug" => "direct"}},
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(id, "post", @ds, scope)

    parsed = %{terms: [], phrases: [], prefixes: [], excludes: []}
    opts = [perspective: :published, fields: "title,slug"] ++ scope

    {hits, _count, _meta} = DocumentsRetriever.search(@ds, parsed, %{}, opts)
    hit = Enum.find(hits, &(&1.doc_id == id))

    # A decoded map, not an undecoded jsonb string — the `type(fragment, :map)`
    # contract. Envelope.render must consume it without a struct.
    assert is_map(hit.content)
    assert hit.content["slug"] == "direct"
    env = Envelope.render(hit, nil, nil)
    assert env["_id"] == id
    assert env["slug"] == "direct"
  end
end
