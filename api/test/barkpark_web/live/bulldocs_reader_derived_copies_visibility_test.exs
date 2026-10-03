defmodule BarkparkWeb.BulldocsReaderDerivedCopiesVisibilityTest do
  @moduledoc """
  task-11acb383532d6169: copies the public reader DERIVES from a paper's own
  fields were built from raw `paper.content`, never through `Envelope`:

    * the og/twitter/JSON-LD head on `/papers/:slug` (`ShareMeta.manifest/4`
      over raw content, including the write-time `content["preview"]`);
    * the BPML source, `GET /papers/:slug/source?format=bpml`
      (`Papers.bpml_paper_map/2` copied `description` and `tags`);
    * the goal rail, keyed off raw `content["goal_id"]`.

  A tenant schema declaring those fields private redacted them on
  `/v1/data/doc` and printed them here to anyone. Each copy now reads from
  `Papers.anonymous_view/2`: the paper rendered by `Envelope.render/3` as the
  anonymous caller under the schema the body render already resolved.

  The write-time preview on `/v1/data/doc` itself was fixed in #21413
  (task-84c95acb380f41e4); its arm here is a regression guard.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, Tenancy}
  alias Barkpark.Plugins.Bulldocs.Events

  @ds "production"
  @slug "dc-paper"
  @goal "dc-goal-zq"

  @description "Head secret description zq12"
  @tag_rationale "Private tag rationale zq13"
  @rail_event "rail-secret-zq14"

  setup do
    Barkpark.LabelFixtures.register_tags!(@ds)

    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    # The tenant's own `paper` schema declares the derived fields' sources
    # private. `event_type` stays public: the head/source control.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "description", "type" => "text", "private" => true},
            %{"name" => "tags", "type" => "array", "private" => true},
            %{"name" => "goal_id", "type" => "string", "private" => true}
          ]
        },
        @ds,
        scope
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          description: @description,
          goal_id: @goal,
          tags: [
            %{"tag" => "fixture-tag-1", "strength" => 90, "rationale" => @tag_rationale},
            %{"tag" => "fixture-tag-2", "strength" => 80, "rationale" => "Second tag rationale."}
          ],
          blocks: [
            %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Derived copies paper"},
            %{
              "id" => "p",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Visible body prose."}]
            }
          ]
        })
      )

    paper = Content.get_public_paper(@slug)

    {:ok, _} =
      Events.create_event(%{
        "goal_id" => @goal,
        "paper_slug" => @slug,
        "event_type" => @rail_event,
        "payload_html" => "<p>rail payload</p>",
        "workspace_id" => paper.workspace_id,
        "project_id" => paper.project_id
      })

    :ok
  end

  test "the reader's og/twitter/JSON-LD head carries no private field", %{conn: conn} do
    html = conn |> get("/papers/#{@slug}") |> html_response(200)
    # Control: the head is there.
    assert html =~ ~s(property="og:url" content="http://localhost:4000/papers/#{@slug}")
    assert html =~ "Visible body prose."

    refute html =~ @description, "the head printed the private description"
  end

  test "the goal rail does not key off a private goal_id", %{conn: conn} do
    html = conn |> get("/papers/#{@slug}") |> html_response(200)

    assert html =~ "Visible body prose."
    refute html =~ @rail_event, "the rail rendered events of the private goal"
    refute html =~ ~s(id="goal-path-rail")
  end

  test "the BPML source prints no private description or tag", %{conn: conn} do
    resp = get(conn, "/papers/#{@slug}/source", %{"format" => "bpml"})
    bpml = resp.resp_body

    # Control: the source is the paper, blocks and all.
    assert resp.status == 200
    assert bpml =~ "Visible body prose."

    refute bpml =~ @description, "BPML printed the private description"
    refute bpml =~ @tag_rationale, "BPML printed a private tag"
  end

  test "the anonymous document read carries no preview entry derived from a private field (#21413 guard)",
       %{conn: conn} do
    body = conn |> get("/v1/data/doc/#{@ds}/paper/#{@slug}") |> json_response(200)
    doc = body["result"]

    # Control: the preview manifest is there.
    assert is_map(doc["preview"]["extensions"])
    refute Jason.encode!(doc) =~ @description
    refute Jason.encode!(doc) =~ @tag_rationale
  end
end
