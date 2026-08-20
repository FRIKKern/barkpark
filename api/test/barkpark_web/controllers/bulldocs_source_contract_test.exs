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

    prior = Application.get_env(:barkpark, :shares)

    Application.put_env(
      :barkpark,
      :shares,
      Sharing.parse("#{workspace.slug}/#{project.slug}/#{dataset}:papers:read")
    )

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior)
    end)

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

    prior = Application.get_env(:barkpark, :shares)

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior)
    end)

    base = "/w/#{workspace.slug}/p/#{project.slug}/d/#{dataset}/papers"

    Application.put_env(
      :barkpark,
      :shares,
      Sharing.parse("#{workspace.slug}/#{project.slug}/#{dataset}:papers:edit")
    )

    published = conn |> get("#{base}/#{slug}/source?perspective=published") |> json_response(200)

    drafts =
      build_conn() |> get("#{base}/#{slug}/source?perspective=drafts") |> json_response(200)

    raw =
      build_conn()
      |> get("#{base}/drafts.#{slug}/source?perspective=raw")
      |> json_response(200)

    assert published["id"] == slug
    assert get_in(published, ["source", "blocks"]) == published_blocks
    assert drafts["id"] == "drafts." <> slug
    assert get_in(drafts, ["source", "blocks"]) == draft_blocks
    assert raw["id"] == "drafts." <> slug
    assert get_in(raw, ["source", "blocks"]) == draft_blocks

    Application.put_env(
      :barkpark,
      :shares,
      Sharing.parse("#{workspace.slug}/#{project.slug}/#{dataset}:papers:read")
    )

    pinned =
      build_conn()
      |> get("#{base}/#{slug}/source?perspective=drafts")
      |> json_response(200)

    assert pinned["id"] == slug
    assert get_in(pinned, ["source", "blocks"]) == published_blocks
  end
end
