defmodule BarkparkWeb.Studio.PaneBuilderStatusViewsDraftTest do
  @moduledoc """
  The default desk gives a type with a `status` select one list per option,
  filtered on the row status and read in the drafts perspective. A published
  or archived document stays in its list while it has a draft: `status` is a
  fact about the stored row, which a draft cannot answer for
  (`Barkpark.Content.Query.DraftShadow`, task-85c4dccf2382c55b).
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "pb_status_views_draft"

  setup do
    Repo.insert!(
      SchemaDefinition.changeset(%SchemaDefinition{}, %{
        name: "post",
        title: "Posts",
        icon: "file-text",
        visibility: "public",
        dataset: @dataset,
        fields: [
          %{"name" => "title", "type" => "string"},
          %{
            "name" => "status",
            "type" => "select",
            "options" => ["draft", "published", "archived"]
          }
        ]
      })
    )

    # plain: published. edited: published, with a draft. shelved: archived, with a draft.
    for id <- ~w(plain edited shelved) do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => id}, @dataset)
      {:ok, _} = Content.publish_document(id, "post", @dataset)
    end

    Repo.update_all(from(d in Document, where: d.doc_id == "shelved" and d.dataset == @dataset),
      set: [status: "archived"]
    )

    for id <- ~w(edited shelved) do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => id <> " v2"}, @dataset)
    end

    :ok
  end

  defp listed(view) do
    {panes, _editor} = PaneBuilder.build(@dataset, ["post", view])
    panes |> List.last() |> Map.fetch!(:items) |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "Published lists a published document that has a draft" do
    assert listed("post-published") == ["edited", "plain"]
  end

  test "Archived lists an archived document that has a draft" do
    assert listed("post-archived") == ["shelved"]
  end
end
