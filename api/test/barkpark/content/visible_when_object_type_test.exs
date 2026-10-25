defmodule Barkpark.Content.VisibleWhenObjectTypeTest do
  @moduledoc """
  task-a20f897d2dbaf824: a `kind: "object"` schema's own fields sit inside the
  object wherever the type is used, so their `visibleWhen` may read that object
  with `"scope": "parent"`, as Sanity's `hidden: ({parent}) => …` does. A
  document schema's top-level field still has no parent and is still refused.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Tenancy
  alias BarkparkWeb.Components.Fields.CompositeField

  @dataset "production"

  @video_only %{
    "field" => "mediaType",
    "operator" => "eq",
    "value" => "video",
    "scope" => "parent"
  }

  @clip_fields [
    %{"name" => "mediaType", "type" => "string"},
    %{"name" => "videoUrl", "type" => "string", "visibleWhen" => @video_only}
  ]

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "vwo-#{suffix}", name: "Visible When Objects"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, scope: [workspace_id: ws.id, project_id: proj.id]}
  end

  defp upsert(attrs, scope), do: Content.upsert_schema(attrs, @dataset, scope)

  test "an object type's top-level field may read its parent", %{scope: scope} do
    object = %{"name" => "clip", "kind" => "object", "title" => "Clip", "fields" => @clip_fields}

    assert {:ok, %{kind: "object"}} = upsert(object, scope)
    assert {:ok, _} = SchemaDefinition.parse(object)
  end

  test "a document schema's top-level field is still refused", %{scope: scope} do
    doc = %{"name" => "clipPage", "title" => "Clip page", "fields" => @clip_fields}

    assert {:error, %Ecto.Changeset{} = cs} = upsert(doc, scope)
    assert {msg, _} = cs.errors[:fields]
    assert msg =~ ~s("videoUrl": visibleWhen "scope": "parent" needs)

    assert {:error, {:visible_when_parent_at_top_level, "videoUrl"}} =
             SchemaDefinition.parse(doc)
  end

  test "Studio reads the object where the type is used as the parent", %{scope: scope} do
    {:ok, _} =
      upsert(
        %{"name" => "clip", "kind" => "object", "title" => "Clip", "fields" => @clip_fields},
        scope
      )

    {:ok, _} =
      upsert(
        %{
          "name" => "clipPage",
          "title" => "Clip page",
          "fields" => [
            # The document's own mediaType must not decide: the object's does.
            %{"name" => "mediaType", "type" => "string"},
            %{"name" => "media", "type" => "clip"}
          ]
        },
        scope
      )

    {:ok, schema} = Content.get_schema("clipPage", @dataset, scope)
    {:ok, %{fields: fields}} = SchemaDefinition.parse(%{"fields" => schema.fields})
    media = Enum.find(fields, &(&1.name == "media"))

    render = fn value ->
      render_component(&CompositeField.composite_field/1, %{
        field: media,
        value: value,
        root: %{"mediaType" => "image", "media" => value},
        path: "doc[media]"
      })
    end

    assert render.(%{"mediaType" => "video"}) =~ ~s(data-subfield-name="videoUrl")
    refute render.(%{"mediaType" => "image"}) =~ ~s(data-subfield-name="videoUrl")
  end
end
