defmodule BarkparkWeb.BulldocsSourceContractTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Sharing}

  test "dataset-scoped canonical source returns identity, revision, and one source arm", %{
    conn: conn
  } do
    dataset = "source-contract-#{System.unique_integer([:positive])}"
    workspace = create_workspace!("source-contract-ws")
    project = create_project!(workspace, "source-contract-project")
    slug = "source-contract-paper"

    blocks = [
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Canonical body"}]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: dataset,
          blocks: blocks,
          workspace_id: workspace.id,
          project_id: project.id
        })
      )

    # arpss-w8: a STORED row, not a bare put_env — Sharing.refresh/0 rebuilds it.
    Barkpark.SharingFixtures.plant_shares!(
      "#{workspace.slug}/#{project.slug}/#{dataset}:papers:read"
    )

    response =
      conn
      |> get("/w/#{workspace.slug}/p/#{project.slug}/d/#{dataset}/papers/#{slug}/source")
      |> json_response(200)

    assert response["id"] == slug
    assert response["_rev"] == paper.rev
    assert response["title"] == paper.title
    assert response["source"] == %{"kind" => "blocks", "blocks" => blocks}
    refute Map.has_key?(response["source"], "html")
  end

  test "perspective selects published, draft-overlay, and exact raw sources while read shares stay pinned",
       %{conn: conn} do
    dataset = "source-perspective-#{System.unique_integer([:positive])}"
    workspace = create_workspace!("source-perspective-ws")
    project = create_project!(workspace, "source-perspective-project")
    slug = "source-perspective-paper"
    scope = [workspace_id: workspace.id, project_id: project.id]

    published_blocks = [
      %{"id" => "published", "type" => "paragraph", "text" => "Published source"}
    ]

    draft_blocks = [
      %{"id" => "draft", "type" => "paragraph", "text" => "Draft source"}
    ]

    {:ok, _published} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: dataset,
          blocks: published_blocks,
          workspace_id: workspace.id,
          project_id: project.id
        })
      )

    {:ok, _draft} =
      Content.upsert_document(
        "paper",
        %{
          "doc_id" => "drafts." <> slug,
          "title" => "Draft title",
          "status" => "draft",
          "content" => %{"blocks" => draft_blocks}
        },
        dataset,
        scope
      )

    Barkpark.SharingFixtures.snapshot_shares!()

    base = "/w/#{workspace.slug}/p/#{project.slug}/d/#{dataset}/papers"

    Barkpark.SharingFixtures.plant_shares!(
      "#{workspace.slug}/#{project.slug}/#{dataset}:papers:edit"
    )

    published = conn |> get("#{base}/#{slug}/source?perspective=published") |> json_response(200)

    drafts =
      scoped_conn() |> get("#{base}/#{slug}/source?perspective=drafts") |> json_response(200)

    raw =
      scoped_conn()
      |> get("#{base}/drafts.#{slug}/source?perspective=raw")
      |> json_response(200)

    assert published["id"] == slug
    assert get_in(published, ["source", "blocks"]) == published_blocks
    assert drafts["id"] == "drafts." <> slug
    assert get_in(drafts, ["source", "blocks"]) == draft_blocks
    assert raw["id"] == "drafts." <> slug
    assert get_in(raw, ["source", "blocks"]) == draft_blocks

    Barkpark.SharingFixtures.plant_shares!(
      "#{workspace.slug}/#{project.slug}/#{dataset}:papers:read"
    )

    pinned =
      scoped_conn()
      |> get("#{base}/#{slug}/source?perspective=drafts")
      |> json_response(200)

    assert pinned["id"] == slug
    assert get_in(pinned, ["source", "blocks"]) == published_blocks
  end
end
