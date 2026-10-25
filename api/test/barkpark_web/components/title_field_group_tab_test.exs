defmodule BarkparkWeb.Components.TitleFieldGroupTabTest do
  @moduledoc """
  task-515960f9b7e4f65a: a `title` field that declares a group shows only on
  that group's tab, as Sanity's Studio draws it. A title with no group keeps
  showing on every tab, and an editor with no selected tab shows it too.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents

  defp schema(title_field) do
    %{
      name: "note",
      title: "Note",
      icon: "file",
      singleton: false,
      groups: [
        %{"name" => "content", "title" => "Content"},
        %{"name" => "meta", "title" => "Meta"}
      ],
      fields: [
        title_field,
        %{"name" => "body", "type" => "text", "title" => "Body", "group" => "content"},
        %{"name" => "keywords", "type" => "string", "title" => "Keywords", "group" => "meta"}
      ]
    }
  end

  defp shell(schema, nav_group) do
    render_component(&StudioComponents.studio_editor_shell/1, %{
      editor_doc: %{
        doc_id: "note-1",
        type: schema.name,
        rev: 1,
        title: "A note",
        status: "published",
        content: %{"body" => "x", "keywords" => "y"}
      },
      editor_schema: schema,
      editor_form: %{"title" => "A note", "body" => "x", "keywords" => "y"},
      editor_is_draft: false,
      dataset: "production",
      validation_errors: %{},
      save_status: "",
      presences: [],
      parent_assigns: %{},
      nav_group: nav_group
    })
  end

  @grouped %{"name" => "title", "type" => "string", "title" => "Heading", "group" => "content"}

  test "a grouped title shows on its own tab" do
    html = shell(schema(@grouped), "content")
    assert html =~ ~s(name="doc[title]")
    assert html =~ ~s(name="doc[body]")
  end

  test "a grouped title does not show on another group's tab" do
    html = shell(schema(@grouped), "meta")
    refute html =~ ~s(name="doc[title]")
    assert html =~ ~s(name="doc[keywords]")
  end

  test "a title in a list of groups shows on each of them" do
    field = Map.put(@grouped, "group", ["content", "meta"])
    assert shell(schema(field), "content") =~ ~s(name="doc[title]")
    assert shell(schema(field), "meta") =~ ~s(name="doc[title]")
  end

  test "a title with no group still shows on every tab" do
    field = Map.delete(@grouped, "group")
    assert shell(schema(field), "content") =~ ~s(name="doc[title]")
    assert shell(schema(field), "meta") =~ ~s(name="doc[title]")
  end

  test "with no selected tab the grouped title shows" do
    assert shell(schema(@grouped), nil) =~ ~s(name="doc[title]")
  end

  test "title_on_tab?/2 follows the title field's group" do
    s = schema(@grouped)
    assert StudioComponents.Editor.title_on_tab?(s, "content")
    refute StudioComponents.Editor.title_on_tab?(s, "meta")
    assert StudioComponents.Editor.title_on_tab?(s, nil)
    assert StudioComponents.Editor.title_on_tab?(%{fields: []}, "meta")
  end
end
