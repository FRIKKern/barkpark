defmodule BarkparkWeb.Studio.PaneBuilderDraftTargetsTest do
  @moduledoc """
  task-af67a9814691ba26 (J23, refs.spec:229): a list row whose preview reads
  through a reference (`subtitle: "author.name"`) shows the referenced
  document's published value when it has a draft too. Sanity's list shows the
  draft. The desk asks for that with `prefer_draft_targets: true`; the old
  Studio does not ask, and its rows are unchanged.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "pb_draft_targets"

  setup do
    for {name, fields, preview} <- [
          {"dt_author", [%{"name" => "name", "type" => "string"}], %{"title" => "name"}},
          {"dt_post",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "author", "type" => "reference", "to" => ["dt_author"]}
           ], %{"title" => "title", "subtitle" => "author.name"}}
        ] do
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        name: name,
        title: name,
        icon: "file",
        visibility: "public",
        dataset: @dataset,
        fields: fields,
        list_preview: preview
      })
      |> Repo.insert!()
    end

    published!("dt_author", "grace", %{"name" => "Grace Hopper"})
    published!("dt_author", "alan", %{"name" => "Alan Turing"})

    published!("dt_post", "p1", %{
      "title" => "Post 1",
      "author" => %{"_ref" => "grace", "_type" => "reference"}
    })

    published!("dt_post", "p2", %{
      "title" => "Post 2",
      "author" => %{"_ref" => "alan", "_type" => "reference"}
    })

    # Grace is being edited: a draft over the published document.
    {:ok, _} =
      Content.upsert_document(
        "dt_author",
        %{"doc_id" => "drafts.grace", "content" => %{"name" => "Grace Hopper X"}},
        @dataset
      )

    :ok
  end

  defp published!(type, id, content) do
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "content" => content}, @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)
  end

  defp subtitles(opts) do
    {panes, _editor} = PaneBuilder.build(@dataset, ["dt_post"], opts)
    for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.id, item.meta}
  end

  test "the desk's rows read a referenced document's draft when it has one" do
    rows = subtitles(prefer_draft_targets: true)
    assert rows["p1"] == "Grace Hopper X"
    assert rows["p2"] == "Alan Turing"
  end

  test "the old Studio's rows still read the published target" do
    rows = subtitles([])
    assert rows["p1"] == "Grace Hopper"
    assert rows["p2"] == "Alan Turing"
  end
end
