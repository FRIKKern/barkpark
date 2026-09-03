defmodule BarkparkWeb.BulldocsSourceControllerTest do
  use BarkparkWeb.ConnCase, async: true

  # NOTE: `show/2`'s `requested_dataset/1` guard (a non-binary `?dataset=` must
  # fall back to the default instead of raising Ecto.Query.CastError → 500) is
  # regression-tested in bulldocs_email_controller_test.exs, where the same
  # three cases cover BOTH reader controllers against one staging-only fixture.
  # Reverting only bulldocs_source_controller.ex reds those tests with the stack
  # at bulldocs_source_controller.ex show_paper/6 — the coverage is real, it just
  # does not live in this file.

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

  test "historical body_html is sanitized before the public source response", %{conn: conn} do
    slug = "source-poisoned-html-#{System.unique_integer([:positive])}"

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          body_html: "<p>Safe original</p>"
        })
      )

    poisoned_html =
      ~s|<p>Meaningful history</p><script>steal()</script><a href="javascript:steal()">link</a>|

    paper
    |> Ecto.Changeset.change(content: Map.put(paper.content, "body_html", poisoned_html))
    |> Repo.update!()

    assert %{
             "source" => %{
               "kind" => "html",
               "html" => sanitized
             }
           } =
             conn
             |> get("/papers/#{slug}/source")
             |> json_response(200)

    assert sanitized =~ "<p>Meaningful history</p>"
    assert sanitized =~ ~s|<a href="#">link</a>|
    refute sanitized =~ "<script"
    refute sanitized =~ "javascript:"
  end
end
