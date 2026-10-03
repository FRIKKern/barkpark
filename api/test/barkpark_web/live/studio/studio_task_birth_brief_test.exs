defmodule BarkparkWeb.Studio.StudioTaskBirthBriefTest do
  @moduledoc """
  A task made with Studio's "+" must be publishable from Studio.

  Found dogfooding: Tasks > + > title, description (20+ characters) and a
  registered weighted tag > Publish answered "Published cancelled: task brief
  is required before publish — set content.brief to PortableDoc …", while the
  Portable brief field in the same editor is read-only ("managed via API").
  `bp task create` composes that brief at birth (`ensureTaskPortableBrief`,
  internal/cli/tasks_create_cmd.go); Studio's birth did not, so a Studio-made
  task could never be published. Studio now seeds the same purpose blocks,
  which `Barkpark.Tasks.BriefMirror` keeps in step with `description`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.TagRegistry

  @dataset "production"

  setup do
    schema = Barkpark.Tasks.task_schema(@dataset)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => schema.name,
          "title" => schema.title,
          "icon" => schema.icon,
          "visibility" => schema.visibility,
          "fields" => schema.fields
        },
        @dataset
      )

    TagRegistry.register!(@dataset)

    {:ok, _} =
      Content.create_document("tag", %{"doc_id" => "editorial", "title" => "editorial"}, @dataset)

    {:ok, _} = Content.publish_document("editorial", "tag", @dataset)
    :ok
  end

  test "a task born in Studio carries a brief, and publishes once described and tagged", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task"))
    render_click(view, "new-document", %{"type" => "task"})

    draft =
      "task"
      |> Content.list_documents(@dataset, perspective: :raw)
      |> Enum.find(&(&1.title == "Untitled"))

    brief = draft.content["brief"]

    assert match?(%{"version" => 1, "blocks" => [_ | _]}, brief),
           "a Studio-born task must carry a brief, as a bp-born one does; got #{inspect(brief)}"

    pub_id = Content.published_id(draft.doc_id)
    description = "A task made in Studio to prove it can be published."

    # What the editor fills in on the Brief tab. Tags are written straight to
    # the draft: this test is about the brief, not the array-row form.
    {:ok, _} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => draft.doc_id,
          "title" => "Studio-made task",
          "content" =>
            Map.merge(draft.content, %{
              "description" => description,
              "tags" => [
                %{
                  "tag" => "editorial",
                  "strength" => 80,
                  "rationale" => "Made in Studio for the editorial desk."
                }
              ]
            })
        },
        @dataset
      )

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task/#{pub_id}"))
    html = render_click(view, "publish")

    refute html =~ "task brief is required", "Studio could not publish the task it made"
    assert {:ok, published} = Content.get_document(pub_id, "task", @dataset)

    purpose =
      Enum.find(published.content["brief"]["blocks"], &(&1["id"] == "purpose-copy"))

    assert [%{"type" => "text", "value" => ^description}] = purpose["content"]
  end
end
