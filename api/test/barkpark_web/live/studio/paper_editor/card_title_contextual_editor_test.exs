defmodule BarkparkWeb.Studio.PaperEditor.CardTitleContextualEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "a plain authored title has one semantic direct owner with selector-safe fallback focus" do
    for {level, tag} <- [
          {1, "h1"},
          {"2", "h2"},
          {3, "h3"},
          {nil, "h2"},
          {:absent, "h2"}
        ] do
      block_id = "card: title/[#{inspect(level)}]#?"

      title = %{
        "type" => "heading",
        "text" => " <Card title> ",
        "qa" => %{"preserve" => true}
      }

      title = if level == :absent, do: title, else: Map.put(title, "level", level)

      tree =
        block_id
        |> card(title)
        |> render_fields()
        |> LazyHTML.from_fragment()

      owner = LazyHTML.query(tree, "[data-paper-card-title-owner]")
      form = LazyHTML.query(tree, "[data-test-id='paper-card-title-form']")
      heading = LazyHTML.query(form, tag)
      textarea = LazyHTML.query(owner, "textarea[name='card-title']")
      paint = LazyHTML.query(owner, "[data-paper-card-title-paint]")
      configure = LazyHTML.query(tree, "[data-test-id='paper-card-title-focus']")
      [field_id] = LazyHTML.attribute(textarea, "id")

      assert field_id =~ ~r/^card-title-[A-Za-z0-9_-]+$/
      refute field_id =~ block_id
      assert LazyHTML.text(paint) == " <Card title> "
      assert LazyHTML.text(textarea) == " <Card title> "
      assert LazyHTML.attribute(paint, "aria-controls") == [field_id]
      assert LazyHTML.attribute(configure, "aria-controls") == [field_id]
      assert hd(LazyHTML.attribute(paint, "phx-click")) =~ "##{field_id}"
      assert hd(LazyHTML.attribute(configure, "phx-click")) =~ "##{field_id}"

      assert LazyHTML.attribute(form, "phx-change") == [
               "paper-block-autosave"
             ]

      assert LazyHTML.attribute(LazyHTML.query(form, "[name]"), "name") == [
               "block_id",
               "card-title"
             ]

      assert Enum.count(LazyHTML.query(tree, "[name='card-title']")) == 1
      assert Enum.count(heading) == 1
    end
  end

  test "empty text and empty content keep the same mounted title owner" do
    for content <- [:absent, nil, []] do
      title = %{"type" => "heading", "level" => "3", "text" => ""}
      title = if content == :absent, do: title, else: Map.put(title, "content", content)

      tree =
        title |> card("empty-#{inspect(content)}") |> render_fields() |> LazyHTML.from_fragment()

      owner = LazyHTML.query(tree, "[data-paper-card-title-owner]")

      assert LazyHTML.attribute(owner, "data-paper-card-title-empty") == ["true"]
      assert Enum.count(LazyHTML.query(owner, "h3")) == 1
      assert Enum.count(LazyHTML.query(owner, "textarea[name='card-title']")) == 1
      assert LazyHTML.text(LazyHTML.query(owner, "textarea")) == ""
      assert Enum.count(LazyHTML.query(tree, "[name='card-title']")) == 1
    end
  end

  test "rich, missing, null, and malformed titles retain Configure or read-only fallback" do
    fallback_titles = [
      {%{
         "type" => "heading",
         "text" => "Hidden text",
         "content" => [%{"type" => "text", "value" => "Visible rich title"}]
       }, true},
      {%{"type" => "heading", "text" => "Hidden text", "content" => %{}}, true},
      {%{"type" => "heading"}, false},
      {%{"type" => "heading", "text" => nil}, false},
      {%{"type" => "heading", "level" => 4, "text" => "Invalid level"}, false},
      {%{"type" => "heading", "level" => "junk", "text" => "Invalid level"}, false}
    ]

    for {{title, content_readonly?}, index} <- Enum.with_index(fallback_titles) do
      tree = title |> card("fallback-#{index}") |> render_fields() |> LazyHTML.from_fragment()

      assert Enum.empty?(LazyHTML.query(tree, "[data-paper-card-title-owner]"))
      assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-card-title-focus']"))

      if content_readonly? do
        assert Enum.empty?(
                 LazyHTML.query(tree, "#card-form-fallback-#{index} [name='card-title']")
               )

        assert Enum.count(LazyHTML.query(tree, "[data-test-id='paper-card-title-readonly']")) == 1
      else
        assert Enum.count(
                 LazyHTML.query(tree, "#card-form-fallback-#{index} [name='card-title']")
               ) == 1
      end
    end

    malformed = card("malformed", %{"type" => "heading", "text" => %{}})
    tree = malformed |> render_fields() |> LazyHTML.from_fragment()
    assert Enum.empty?(LazyHTML.query(tree, "[data-paper-card-title-owner]"))
    assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-card-editor']"))
    assert LazyHTML.text(tree) =~ "original content is preserved"
  end

  defp render_fields(block) do
    render_component(&PaperEditor.paper_block_fields/1,
      block: block,
      root_slug: "paper",
      doc_key: "production:paper:paper",
      paper_rev: 7
    )
  end

  defp card(id, title) when is_binary(id),
    do: %{"id" => id, "type" => "card", "slots" => %{"title" => [title]}}

  defp card(title, id), do: card(id, title)
end
