defmodule BarkparkWeb.HeldWrites do
  @moduledoc """
  The four whole-form writes of the editor that are not a post of the form
  (task-881a41cd3227e73c): an array op, a tag press, a tree codelist pick
  and a slug Generate, each on a field of its own, and the schema fields
  they need. `HeldWholeFormWriteTest` and `HeldRichTextWholeFormWriteTest`
  run each one while another field is held.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  @doc "The fields the writes act on, for a schema's `fields`."
  def fields do
    list = "onixedit:held-tree-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Codelists.register("onixedit", list, %{
        issue: "1",
        name: "Held tree",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children:
              for(
                i <- 1..101,
                do: %{code: "FB#{i}", translations: [%{language: "eng", label: "F#{i}"}]}
              )
          }
        ]
      })

    [
      %{
        "name" => "items",
        "title" => "Items",
        "type" => "array",
        "of" => [%{"type" => "string"}]
      },
      %{
        "name" => "tags",
        "title" => "Tags",
        "type" => "arrayOf",
        "of" => %{"type" => "string"},
        "options" => %{"layout" => "tags"}
      },
      %{"name" => "subject", "title" => "Subject", "type" => "codelist", "codelistId" => list},
      %{"name" => "slug", "title" => "Slug", "type" => "slug"}
    ]
  end

  @doc "The stored values the writes start from."
  def content, do: %{"items" => ["x", "y"], "tags" => ["t1"]}

  @doc "The write paths, by name."
  def paths, do: [:array_op, :tags, :pick, :slug]

  @doc "Runs `path` on `view`, the document `c.type`/`c.id`."
  def run(view, _c, :array_op),
    do:
      EditorPost.press(view, "array_op", %{
        "action" => "remove_row",
        "field" => "items",
        "path" => "doc[items]",
        "index" => "0"
      })

  def run(view, _c, :tags),
    do:
      EditorPost.press(view, "array_op", %{
        "action" => "add_tag",
        "field" => "tags",
        "value" => "t2"
      })

  def run(view, c, :pick) do
    mark = %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.id)}
    send(view.pid, {:tree_codelist_pick, %{name: "doc[subject]", value: "FB1", press: mark}})
    render(view)
  end

  def run(view, _c, :slug), do: EditorPost.press(view, "slug-generate", %{"field" => "slug"})

  @doc "The write landed: its own field is stored as written."
  def landed(c, path) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    content = doc.content || %{}

    case path do
      :array_op -> assert content["items"] == ["y"]
      :tags -> assert content["tags"] == ["t1", "t2"]
      :pick -> assert content["subject"] == "FB1"
      :slug -> assert content["slug"] not in [nil, ""]
    end
  end
end
