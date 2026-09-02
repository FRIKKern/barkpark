defmodule Barkpark.Content.PaperPublishGateReaderScopeTest do
  @moduledoc """
  The Paper publish gate's SCOPE must descend from what the READERS render, not
  from which key the writer happened to use.

  `Barkpark.PortableDoc.Projection.read_blocks/1` is the one locator every Paper
  reader goes through, and it accepts three STORED locations for a block list:
  top-level `"blocks"`, `"body"."blocks"`, and a bare list `"body"`. Before this
  suite the gate pattern-matched only the first, so the same bytes published
  ungated under the other two — a verdict decided by the writer's key.

  Every test here plants the SAME blocks at each location and asserts the gate
  answers IDENTICALLY. Each location is first proven reader-rendered by asserting
  `read_blocks/1` finds exactly the planted list there, so a future change that
  drops a location from the reader also reds this file instead of silently
  making the parity assertions vacuous.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.Repo

  @dataset "paper_publish_gate_reader_scope_test"

  # The three STORED locations `read_blocks/1` accepts, named by the shape a
  # writer produces. `:top` is what the Studio canvas writes; `:body_blocks` is
  # what `Projection.project/3` and the wave-Paper authoring path write;
  # `:body_list` is the bare-list dialect.
  @locations [:top, :body_blocks, :body_list]

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp place(:top, blocks), do: %{"blocks" => blocks}
  defp place(:body_blocks, blocks), do: %{"body" => %{"blocks" => blocks}}
  defp place(:body_list, blocks), do: %{"body" => blocks}

  defp read_back(:top, content), do: content["blocks"]
  defp read_back(:body_blocks, content), do: content["body"]["blocks"]
  defp read_back(:body_list, content), do: content["body"]

  defp insert_draft!(id, location, blocks) do
    content =
      Barkpark.LabelFixtures.with_registered_labels(place(location, blocks), @dataset)

    # NON-VACUITY: this location is only worth gating because the readers read
    # it. If `read_blocks/1` ever stops finding the planted list here, this
    # assertion fires instead of the parity assertions quietly passing on a
    # location nobody renders.
    assert Projection.read_blocks(content) == blocks

    %Document{}
    |> Document.changeset(%{
      "doc_id" => "drafts." <> id,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => "Reader-scope gate #{id}",
      "status" => "draft",
      "content" => content,
      "rev" => "source-rev-" <> id
    })
    |> Repo.insert!()

    id
  end

  # An item no reader can turn into inline content — the shape the gate has
  # always refused when it happened to be stored under the top-level key.
  defp unrenderable_blocks do
    [%{"type" => "list", "items" => [%{"label" => "stranded prose"}]}]
  end

  # The plainest authoring shape: a table whose cells are bare strings and a
  # list whose items are bare strings. Both are rescued by
  # `BlockOps.normalize_render_shapes/1`, so the gate must ACCEPT them — at
  # every location, not only under the top-level key.
  defp string_leaf_blocks do
    [
      %{"type" => "table", "head" => ["Surface"], "rows" => [["studio"], ["share link"]]},
      %{"type" => "list", "items" => ["first", "second"]}
    ]
  end

  describe "the gate's scope" do
    test "refuses the same unrenderable blocks at EVERY reader-rendered location" do
      verdicts =
        Map.new(@locations, fn location ->
          id = insert_draft!("refuse-#{location}", location, unrenderable_blocks())
          {location, Content.publish_document(id, "paper", @dataset)}
        end)

      for {location, verdict} <- verdicts do
        # `match?/2` keeps the message LIVE — a bare `assert pattern = verdict`
        # raises MatchError before assert/2 ever reads its message, so the
        # location that failed would never be named.
        assert match?(
                 {:error,
                  {:invalid_paper_structure,
                   %{"blocks" => ["blocks[0].items[0] has no renderable inline content"]}}},
                 verdict
               ),
               "location #{inspect(location)} published UNGATED: #{inspect(verdict)}"
      end

      # One verdict, three writers. This is the whole point of the row: the
      # answer is a property of the content, not of the key.
      assert verdicts |> Map.values() |> Enum.uniq() |> length() == 1
    end

    test "leaves the refused draft intact and unpublished at EVERY location" do
      for location <- @locations do
        id = insert_draft!("intact-#{location}", location, unrenderable_blocks())

        assert {:error, {:invalid_paper_structure, _}} =
                 Content.publish_document(id, "paper", @dataset)

        assert {:ok, _draft} = Content.get_document("drafts." <> id, "paper", @dataset)
        assert {:error, :not_found} = Content.get_document(id, "paper", @dataset)
      end
    end
  end

  describe "bare-string table cells and list items" do
    test "publish and normalise IDENTICALLY at every reader-rendered location" do
      normalised =
        Map.new(@locations, fn location ->
          id = insert_draft!("strings-#{location}", location, string_leaf_blocks())

          assert {:ok, published} = Content.publish_document(id, "paper", @dataset)

          # The normalised list is written back WHERE IT WAS READ FROM — a
          # body-located paper must not acquire a top-level "blocks" key it
          # never had, which would flip reader precedence under the author.
          if location != :top do
            refute Map.has_key?(published.content, "blocks"),
                   "publish invented a top-level blocks key for #{inspect(location)}"
          end

          {location, read_back(location, published.content)}
        end)

      [table, list] = normalised[:top]

      # The bare-string cells became canonical inline arrays rather than being
      # refused with a sentence claiming readers cannot render them.
      assert table["head"] == [[%{"type" => "text", "value" => "Surface"}]]

      assert table["rows"] == [
               [[%{"type" => "text", "value" => "studio"}]],
               [[%{"type" => "text", "value" => "share link"}]]
             ]

      assert list["items"] == [
               [%{"type" => "text", "value" => "first"}],
               [%{"type" => "text", "value" => "second"}]
             ]

      # Same bytes in, same bytes out, wherever the writer put them.
      assert normalised |> Map.values() |> Enum.uniq() |> length() == 1
    end
  end

  describe "shapes with no stored block list" do
    test "a markdown-string body still publishes — nothing authored to refuse" do
      content =
        Barkpark.LabelFixtures.with_registered_labels(
          %{"body" => "# Legacy\n\nStill readable."},
          @dataset
        )

      # The readers DO render this (read_blocks synthesises from markdown), but
      # the blocks are machine-produced at read time and never stored, so the
      # gate has no authored shape to judge and must not manufacture a refusal.
      assert is_list(Projection.read_blocks(content))

      %Document{}
      |> Document.changeset(%{
        "doc_id" => "drafts.markdown-body",
        "type" => "paper",
        "dataset" => @dataset,
        "title" => "Reader-scope gate markdown",
        "status" => "draft",
        "content" => content,
        "rev" => "source-rev-markdown"
      })
      |> Repo.insert!()

      assert {:ok, published} = Content.publish_document("markdown-body", "paper", @dataset)
      assert published.content["body"] == "# Legacy\n\nStill readable."
    end

    test "a DECLARED but non-list top-level blocks key still refuses" do
      content =
        Barkpark.LabelFixtures.with_registered_labels(
          %{"blocks" => "not-a-list", "body" => %{"blocks" => []}},
          @dataset
        )

      %Document{}
      |> Document.changeset(%{
        "doc_id" => "drafts.declared-nonlist",
        "type" => "paper",
        "dataset" => @dataset,
        "title" => "Reader-scope gate declared non-list",
        "status" => "draft",
        "content" => content,
        "rev" => "source-rev-declared-nonlist"
      })
      |> Repo.insert!()

      # The refusal arrives as a proper error TUPLE out of publish_document/4.
      # The arm this replaced returned `validate_render_shapes/1`'s bare `:ok`
      # into a `with` binding `{:ok, draft}` — reachable the moment that
      # function grows a non-list success case.
      assert {:error, {:invalid_paper_structure, %{"blocks" => [message]}}} =
               Content.publish_document("declared-nonlist", "paper", @dataset)

      assert message =~ "must be an array"
    end
  end
end
