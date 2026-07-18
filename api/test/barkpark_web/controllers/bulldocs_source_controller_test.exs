defmodule BarkparkWeb.BulldocsSourceControllerTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, Repo}

  test "missing canonical identity is the same explicit 404 as the GUI", %{conn: conn} do
    assert conn |> get("/papers/source-never-published/source") |> response(404) == "not found"
  end

  test "semantic-empty and conflicting sources fail explicitly instead of returning a 200 shell",
       %{conn: conn} do
    empty_slug = "source-empty-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: empty_slug, body_html: "   "})
      )

    assert %{"error" => %{"code" => "semantic_empty"}} =
             conn
             |> get("/papers/#{empty_slug}/source")
             |> json_response(422)

    mixed_slug = "source-mixed-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Canonical blocks"}]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: mixed_slug, blocks: blocks})
      )

    paper
    |> Ecto.Changeset.change(content: Map.put(paper.content, "body_html", "<p>conflict</p>"))
    |> Repo.update!()

    assert %{"error" => %{"code" => "ambiguous_source"}} =
             build_conn()
             |> get("/papers/#{mixed_slug}/source")
             |> json_response(422)
  end
end
