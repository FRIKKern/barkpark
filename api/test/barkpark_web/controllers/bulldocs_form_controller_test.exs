defmodule BarkparkWeb.BulldocsFormControllerTest do
  @moduledoc """
  The anonymous form-submission endpoint (study play #5): paper-anchored,
  question-id allowlisted, size-capped, honeypotted. Every test posts
  anonymously — the whole point of the `:public_api` bucket.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  defp path(slug), do: "/v1/plugins/bulldocs/papers/#{slug}/form-responses"

  defp seed_paper!(blocks) do
    {workspace, project} = ensure_default_scope!()
    slug = "form-paper-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: blocks,
          workspace_id: workspace.id,
          project_id: project.id
        })
      )

    slug
  end

  defp form_blocks do
    [
      %{
        "id" => "grill",
        "type" => "form",
        "questions" => [
          %{"id" => "q-fit", "prompt" => "Does it fit?", "type" => "yesno"},
          %{"id" => "q-notes", "prompt" => "Notes", "type" => "text"}
        ]
      }
    ]
  end

  defp responses_for(slug) do
    from(d in Document,
      where: d.type == "form_response",
      where: fragment("?->>'paper_slug' = ?", d.content, ^slug)
    )
    |> Repo.all()
  end

  test "happy path: stores the allowlisted answers and returns 201 with the id", %{conn: conn} do
    slug = seed_paper!(form_blocks())

    resp =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes", "q-notes" => "ship it"}})
      |> json_response(201)

    assert resp["ok"] == true
    assert is_binary(resp["id"])

    assert [doc] = responses_for(slug)
    assert doc.content["answers"] == %{"q-fit" => "Yes", "q-notes" => "ship it"}
    assert is_binary(doc.content["submitted_at"])
  end

  test "unknown answer keys are dropped; all-unknown filters to a 422", %{conn: conn} do
    slug = seed_paper!(form_blocks())

    resp =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes", "smuggled" => "x"}})
      |> json_response(201)

    assert resp["ok"] == true
    assert [doc] = responses_for(slug)
    refute Map.has_key?(doc.content["answers"], "smuggled")

    slug2 = seed_paper!(form_blocks())

    assert %{"error" => %{"code" => "no_answers"}} =
             conn
             |> post(path(slug2), %{"answers" => %{"smuggled" => "x"}})
             |> json_response(422)

    assert responses_for(slug2) == []
  end

  test "a paper without a form block is a 422; an unknown slug a 404", %{conn: conn} do
    slug =
      seed_paper!([
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "hi"}]}
      ])

    assert %{"error" => %{"code" => "no_form"}} =
             conn |> post(path(slug), %{"answers" => %{"q" => "a"}}) |> json_response(422)

    assert %{"error" => %{"code" => "paper_not_found"}} =
             conn
             |> post(path("never-published-#{System.unique_integer([:positive])}"), %{
               "answers" => %{"q" => "a"}
             })
             |> json_response(404)
  end

  test "the honeypot returns a vacuous 201 and writes nothing", %{conn: conn} do
    slug = seed_paper!(form_blocks())

    resp =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes"}, "website" => "spam.example"})
      |> json_response(201)

    assert resp["ok"] == true
    refute Map.has_key?(resp, "id")
    assert responses_for(slug) == []
  end

  test "oversize inputs are capped, junk value types dropped", %{conn: conn} do
    slug = seed_paper!(form_blocks())
    long = String.duplicate("a", 5_000)

    conn
    |> post(path(slug), %{
      "answers" => %{"q-notes" => long, "q-fit" => %{"nested" => "junk"}}
    })
    |> json_response(201)

    assert [doc] = responses_for(slug)
    assert String.length(doc.content["answers"]["q-notes"]) == 4_000
    refute Map.has_key?(doc.content["answers"], "q-fit")
  end

  test "forms nested inside containers are still discovered", %{conn: conn} do
    slug =
      seed_paper!([
        %{"id" => "cols", "type" => "columns", "columns" => [form_blocks(), []]}
      ])

    assert %{"ok" => true} =
             conn
             |> post(path(slug), %{"answers" => %{"q-fit" => "No"}})
             |> json_response(201)
  end

  test "the form_response schema is private: anonymous read API never serves responses", %{
    conn: conn
  } do
    slug = seed_paper!(form_blocks())

    %{"ok" => true, "id" => id} =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes"}})
      |> json_response(201)

    anon = build_conn()
    resp = anon |> get("/v1/data/doc/production/form_response/#{id}")
    assert resp.status in [401, 403, 404]
  end
end
