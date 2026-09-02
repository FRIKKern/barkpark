defmodule Barkpark.Content.PublishTitleDivergenceGateTest do
  @moduledoc """
  The publish door refuses a document whose `title` COLUMN disagrees with its
  BOUND title block.

  That divergence is what `doc patch <type> <id> --set title=X` leaves behind on
  a blocks-bearing document: `Content.Mutations` writes `attrs["title"]` from the
  patch's `set` map while dropping `"title"` from the merged content, and
  `Writer.maybe_project_document_content/2` then re-derives `content["title"]`
  from the (untouched) bound block. The patch answers 200 with a fresh `_rev` and
  the value is gone. These tests pin the PUBLISH consequence: the divergence must
  not be copied onto the published row, where `search_vector` indexes both titles
  and no reader can tell which was meant.

  The permit arms matter as much as the refusal: a document whose sides AGREE, a
  document with FREE blocks only (the paper shape), and a document with NO block
  list must all still publish.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "publish_title_divergence_gate_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp insert_draft!(id, column_title, content) do
    content = Barkpark.LabelFixtures.with_registered_labels(content, @dataset)

    %Document{}
    |> Document.changeset(%{
      "doc_id" => "drafts." <> id,
      "type" => "post",
      "dataset" => @dataset,
      "title" => column_title,
      "status" => "draft",
      "content" => content,
      "rev" => "source-rev-" <> id
    })
    |> Repo.insert!()
  end

  defp bound_title(value),
    do: %{"id" => "b1", "type" => "field-string", "fieldName" => "title", "value" => value}

  describe "refusal" do
    test "a title column that disagrees with the bound title block is refused, naming both" do
      insert_draft!("diverged", "T9", %{
        "title" => "T0",
        "blocks" => [bound_title("T0")]
      })

      assert {:error, {:halted, message}} =
               Content.publish_document("diverged", "post", @dataset)

      # The message must name BOTH values — a refusal that says only "the titles
      # disagree" leaves the author guessing which row they are looking at.
      assert message =~ "T9"
      assert message =~ "T0"
      assert message =~ "doc patch --set title="

      # Side-effect-free: the gate runs before the wall and the :before_publish
      # hook, so no published row may exist after the refusal.
      assert {:error, :not_found} = Content.get_document("diverged", "post", @dataset)
    end
  end

  describe "permit arms" do
    test "a document whose column and bound block AGREE still publishes" do
      insert_draft!("agrees", "T0", %{
        "title" => "T0",
        "blocks" => [bound_title("T0")]
      })

      assert {:ok, published} = Content.publish_document("agrees", "post", @dataset)
      assert published.title == "T0"
      assert published.content["title"] == "T0"
    end

    test "a FREE title block (no fieldName) is not a bound block and never gates" do
      # The paper shape: a role-titled free block. Projection never derives
      # content["title"] from it, so a differing column is not a divergence.
      insert_draft!("free", "T9", %{
        "blocks" => [%{"id" => "b1", "type" => "heading", "role" => "title", "text" => "T0"}]
      })

      assert {:ok, published} = Content.publish_document("free", "post", @dataset)
      assert published.title == "T9"
    end

    test "a document with NO block list publishes unchanged (the legacy field-map save)" do
      insert_draft!("noblocks", "T9", %{"title" => "T0"})

      assert {:ok, published} = Content.publish_document("noblocks", "post", @dataset)
      assert published.title == "T9"
    end

    test "a blank bound title block value is a cleared index entry, not a competing title" do
      insert_draft!("blank", "T9", %{"blocks" => [bound_title("")]})

      assert {:ok, published} = Content.publish_document("blank", "post", @dataset)
      assert published.title == "T9"
    end
  end
end
