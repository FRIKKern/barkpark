defmodule Barkpark.Content.Papers.BodyLossesTest do
  @moduledoc """
  The body-loss report over a planted history on the local test database: a
  write that empties a callout's body, then a recorded BPML push that drops a
  list item's children.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.{Content, LabelFixtures, Repo}
  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.Content.Papers.BodyLosses

  defp t(v), do: %{"type" => "text", "value" => v}
  defp para(id, v), do: %{"id" => id, "type" => "paragraph", "content" => [t(v)]}

  defp list(children),
    do: %{
      "id" => "l",
      "type" => "list",
      "items" => [%{"content" => [t("parent")], "children" => children}]
    }

  defp callout(body),
    do: %{
      "id" => "c1",
      "type" => "callout",
      "content" => [t("Note.")],
      "slots" => %{"body" => body}
    }

  defp full,
    do: [list([para("k1", "One."), para("k2", "Two.")]), callout([para("c1-a", "Body.")])]

  defp no_body, do: [list([para("k1", "One."), para("k2", "Two.")]), callout([])]
  defp no_children, do: [list([]), callout([])]

  defp plant!(paper, action, blocks, seconds) do
    Repo.insert!(%Revision{
      doc_id: paper.doc_id,
      type: "paper",
      dataset: paper.dataset,
      dataset_id: paper.dataset_id,
      workspace_id: paper.workspace_id,
      project_id: paper.project_id,
      title: paper.title,
      status: paper.status,
      action: action,
      content: Map.put(paper.content, "blocks", blocks),
      inserted_at: DateTime.add(DateTime.utc_now(), seconds, :second)
    })
  end

  defp revisions(slug),
    do:
      Repo.all(
        from r in Revision, where: r.doc_id == ^slug, order_by: [asc: r.inserted_at, asc: r.id]
      )

  test "names the step that lost each body, and a push step as a push" do
    slug = "body-losses-#{System.unique_integer([:positive])}"
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: full()}))
    paper = Repo.get!(Document, paper.id)

    edited = plant!(paper, "api-ops", no_body(), 60)
    pushed = plant!(paper, "bpml-push", no_body(), 120)

    paper
    |> Ecto.Changeset.change(content: Map.put(paper.content, "blocks", no_children()))
    |> Repo.update!()

    [first | _] = revisions(slug)
    first_label = "revision #{first.id} (#{first.action}, #{first.inserted_at})"
    edited_label = "revision #{edited.id} (api-ops, #{edited.inserted_at})"
    pushed_label = "revision #{pushed.id} (bpml-push, #{pushed.inserted_at})"
    counts = {Repo.aggregate(Revision, :count), Repo.aggregate(Document, :count)}
    row = Repo.get!(Document, paper.id)

    lines = BodyLosses.report(slug, paper.dataset)

    states = length(revisions(slug)) + 1

    assert Enum.at(lines, 0) ==
             "Paper #{slug} (#{paper.dataset}): #{states} stored states, 1 recorded BPML pushes."

    assert Enum.at(lines, 1) =~ "cannot be told apart"

    assert Enum.drop(lines, 2) == [
             "not a recorded push, #{first_label} -> #{edited_label}: blocks[1] callout c1 lost its body (1 block)",
             "BPML push, #{pushed_label} -> the Paper now: blocks[0] item 0 (\"parent\") lost its 2 child blocks"
           ]

    # Read-only: nothing was written.
    assert {Repo.aggregate(Revision, :count), Repo.aggregate(Document, :count)} == counts
    assert Repo.get!(Document, paper.id) == row
  end

  test "a history that kept every body says so" do
    slug = "body-losses-kept-#{System.unique_integer([:positive])}"
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: full()}))

    assert List.last(BodyLosses.report(slug, paper.dataset)) ==
             "No list item children or callout bodies disappeared."
  end

  test "an item found again by its words, or a list or callout removed whole, is not a loss" do
    moved = [para("p0", "First."), list([para("k1", "One.")])]
    assert BodyLosses.losses([list([para("k1", "One.")])], moved) == []
    assert BodyLosses.losses(full(), [para("p0", "All gone.")]) == []
  end
end
