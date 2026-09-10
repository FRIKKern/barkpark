defmodule BarkparkWeb.Components.TitlelessTypesE18Test do
  @moduledoc """
  Gyldendal parity E1.8 (task-b732cbaf366456e9, criteria 1–2) — the editor
  shell on a NON-singleton type without a `title` field whose rows are backed
  by `list_preview.title` (the twin's `author`): no synthetic Title input, the
  header shows the list-preview value, and the `name` field keeps its own label.
  The E1.5 contract stays: a titleless type with NO list_preview.title keeps the
  Title input, because nothing else can name its rows.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents

  @author %{
    name: "author",
    title: "Forfatter",
    icon: "user",
    singleton: false,
    list_preview: %{"title" => "name", "subtitle" => "slug"},
    fields: [
      %{"name" => "name", "type" => "string", "title" => "Navn"},
      %{"name" => "slug", "type" => "slug", "title" => "Slug (URL)"}
    ]
  }

  defp shell(schema, doc_title, content, form) do
    render_component(&StudioComponents.studio_editor_shell/1, %{
      editor_doc: %{
        doc_id: "author-graff",
        type: schema.name,
        rev: 1,
        title: doc_title,
        status: "published",
        content: content
      },
      editor_schema: schema,
      editor_form: form,
      editor_is_draft: false,
      dataset: "production",
      validation_errors: %{},
      save_status: "",
      presences: [],
      parent_assigns: %{},
      nav_group: nil
    })
  end

  test "a non-singleton titleless type with list_preview.title renders no synthetic Title input, and the name field keeps its own label" do
    html =
      shell(@author, nil, %{"name" => "Sverre Graff"}, %{
        "name" => "Sverre Graff",
        "slug" => "sverre-graff"
      })

    refute html =~ ~s(name="doc[title]"), "the synthetic Title input is still rendered"
    refute html =~ ~r{>\s*Title\s*<}, "a hard-coded «Title» label survives"
    assert html =~ "Navn"
    assert html =~ ~s(name="doc[name]")
  end

  test "the header shows the list_preview.title value when the title column is blank" do
    html = shell(@author, nil, %{"name" => "Sverre Graff"}, %{"name" => "Sverre Graff"})
    assert html =~ ~s(<span class="pane-header-title">Sverre Graff</span>)
    refute html =~ "Untitled"
  end

  test "a stored title column still wins over the preview value" do
    html =
      shell(@author, "Stored Title", %{"name" => "Sverre Graff"}, %{"name" => "Sverre Graff"})

    assert html =~ ~s(<span class="pane-header-title">Stored Title</span>)
  end

  test "a titleless type WITHOUT list_preview.title keeps the Title input (E1.5 contract unchanged)" do
    schema = %{
      name: "note",
      title: "Note",
      icon: "file",
      singleton: false,
      fields: [%{"name" => "body", "type" => "text"}]
    }

    html = shell(schema, nil, %{"body" => "x"}, %{"title" => "", "body" => "x"})
    assert html =~ ~s(name="doc[title]")
    assert html =~ "Untitled"
  end

  test "a type WITH a title field is unchanged: the declared title field renders, no preview fallback" do
    schema = %{
      name: "series",
      title: "Serie",
      icon: "layers",
      singleton: false,
      list_preview: %{"title" => "blurb"},
      fields: [
        %{"name" => "title", "type" => "string", "title" => "Tittel"},
        %{"name" => "blurb", "type" => "text"}
      ]
    }

    html =
      shell(schema, nil, %{"blurb" => "Not the title"}, %{
        "title" => "",
        "blurb" => "Not the title"
      })

    assert html =~ ~s(name="doc[title]")
    assert html =~ "Untitled"
    refute html =~ ~s(<span class="pane-header-title">Not the title</span>)
  end
end
