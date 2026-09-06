defmodule Barkpark.Content.Papers.RevisionFencedDuplicateIdentityTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @dataset "production"
  @duplicate "duplicate-form"

  test "revision-fenced single, batch, and form writes reject globally ambiguous ids" do
    for kind <- [:single, :batch, :form] do
      {slug, rev, before} = seed_duplicate_paper!(kind)

      result =
        case kind do
          :single ->
            Content.apply_paper_block_op(slug, patch(@duplicate, "Wrong target"), @dataset,
              if_rev: rev
            )

          :batch ->
            Content.apply_paper_block_ops_once(
              slug,
              [patch(@duplicate, "Wrong target")],
              @dataset,
              Ecto.UUID.generate(),
              "user:duplicate-batch",
              if_rev: rev
            )

          :form ->
            Content.apply_paper_block_form_once(
              slug,
              "block_form:v1",
              %{"block_id" => @duplicate, "title" => "Wrong target"},
              @dataset,
              Ecto.UUID.generate(),
              "user:duplicate-form",
              fn _blocks -> flunk("ambiguous ids must be rejected before form resolution") end,
              if_rev: rev
            )
        end

      assert result == {:error, {:duplicate_id, @duplicate}}
      assert Content.get_paper(slug).content == before
    end
  end

  test "stale revision refusal precedes duplicate-id projection on every fenced path" do
    {slug, rev, before} = seed_duplicate_paper!(:stale)
    stale = rev - 1

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_op(slug, patch(@duplicate, "Single"), @dataset,
               if_rev: stale
             )

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch(@duplicate, "Batch")],
               @dataset,
               Ecto.UUID.generate(),
               "user:stale-batch",
               if_rev: stale
             )

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"block_id" => @duplicate, "title" => "Form"},
               @dataset,
               Ecto.UUID.generate(),
               "user:stale-form",
               fn _blocks -> flunk("stale form must not resolve") end,
               if_rev: stale
             )

    assert Content.get_paper(slug).content == before
  end

  test "a unique revision-fenced source still applies normally" do
    slug = unique("unique")

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          style: "article",
          blocks: [
            %{
              "id" => "columns",
              "type" => "columns",
              "columns" => [[form("nested-form", "Nested")]]
            },
            form("top-form", "Top")
          ]
        })
      )

    rev = paper.content["rev"]

    assert {:ok, %{rev: next_rev, block_id: "top-form"}} =
             Content.apply_paper_block_op(slug, patch("top-form", "Changed"), @dataset,
               if_rev: rev
             )

    assert next_rev == rev + 1

    assert Enum.find(Content.paper_blocks(slug), &(&1["id"] == "top-form"))["title"] ==
             "Changed"
  end

  test "an unfenced legacy write retains its existing duplicate-id traversal behavior" do
    {slug, rev, _before} = seed_duplicate_paper!(:legacy)

    assert {:ok, %{rev: next_rev}} =
             Content.apply_paper_block_op(slug, patch(@duplicate, "Legacy accepted"), @dataset)

    assert next_rev == rev + 1
    [columns, top_level] = Content.paper_blocks(slug)
    assert get_in(columns, ["columns", Access.at(0), Access.at(0), "title"]) == "Legacy accepted"
    assert top_level["title"] == "Top-level"
  end

  defp seed_duplicate_paper!(suffix) do
    slug = unique("duplicate-#{suffix}")

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          style: "article",
          blocks: [
            %{
              "id" => "columns",
              "type" => "columns",
              "unknown" => %{"keep" => true},
              "columns" => [[form(@duplicate, "Nested")]]
            },
            form(@duplicate, "Top-level")
          ]
        })
      )

    {slug, paper.content["rev"], paper.content}
  end

  defp form(id, title), do: %{"id" => id, "type" => "form", "title" => title}

  defp patch(id, title),
    do: %{"op" => "patch-block", "id" => id, "patch" => %{"title" => title}}

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
