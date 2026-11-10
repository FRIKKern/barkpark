defmodule BarkparkWeb.Studio.DeskEditorStructuredTest do
  @moduledoc """
  The desk's editor pane (the last document of a desk chain is edited by the
  Studio's own editor, `DeskLive` → `StudioLive`) with structured fields:
  arrays of references, objects and strings, multi-type arrays, images, an
  array of images, codelists (flat, combobox, tree), localizedText, Portable
  Text with its block dialog, and a block-canvas richText field.

  Probed in a real browser first (editing lane, worker w3): every one of these
  behaves the same in the desk pane as in the plain Studio. These tests pin
  that for the split refactor. The one red is the tree codelist, which is
  broken in the plain Studio too.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]
    n = System.unique_integer([:positive])

    t = %{
      target: "w3t_target_#{n}",
      card: "w3t_card_#{n}",
      quote: "w3t_quote_#{n}",
      struct: "w3t_struct_#{n}",
      roles: "w3t#{n}:roles",
      big: "w3t#{n}:big",
      tree: "w3t#{n}:tree"
    }

    plugin = "w3t#{n}"

    {:ok, _} =
      Codelists.register(plugin, t.roles, %{
        issue: "1",
        name: "roles",
        values:
          for(
            {c, l} <- [{"A01", "Author"}, {"B01", "Editor"}, {"B06", "Translator"}],
            do: %{code: c, translations: [%{language: "eng", label: l}]}
          )
      })

    {:ok, _} =
      Codelists.register(plugin, t.big, %{
        issue: "1",
        name: "big",
        values:
          for(
            i <- 1..120,
            do: %{
              code: "C#{String.pad_leading("#{i}", 3, "0")}",
              translations: [%{language: "eng", label: "Code #{i}"}]
            }
          )
      })

    {:ok, _} =
      Codelists.register(plugin, t.tree, %{
        issue: "1",
        name: "tree",
        values:
          for(
            p <- 1..12,
            do: %{
              code: "P#{p}",
              translations: [%{language: "eng", label: "Parent #{p}"}],
              children:
                for(
                  c <- 1..10,
                  do: %{
                    code: "P#{p}C#{c}",
                    translations: [%{language: "eng", label: "Child #{p}.#{c}"}]
                  }
                )
            }
          )
      })

    str = fn name -> %{"name" => name, "title" => String.capitalize(name), "type" => "string"} end

    for schema <- [
          %{
            "name" => t.target,
            "title" => "Targets",
            "visibility" => "public",
            "fields" => [str.("title")]
          },
          %{
            "name" => t.card,
            "kind" => "object",
            "title" => "Card",
            "fields" => [str.("heading"), %{"name" => "note", "type" => "text"}]
          },
          %{
            "name" => t.quote,
            "kind" => "object",
            "title" => "Quote",
            "fields" => [%{"name" => "quote", "type" => "text"}, str.("author")]
          },
          %{
            "name" => t.struct,
            "title" => "Structured",
            "visibility" => "public",
            "fields" => [
              str.("title"),
              %{
                "name" => "refs",
                "type" => "arrayOf",
                "ordered" => true,
                "of" => %{"type" => "reference", "refType" => t.target}
              },
              %{
                "name" => "cards",
                "type" => "arrayOf",
                "ordered" => true,
                "of" => %{
                  "type" => "composite",
                  "fields" => [str.("heading"), %{"name" => "note", "type" => "text"}]
                }
              },
              %{
                "name" => "sections",
                "type" => "arrayOf",
                "ordered" => true,
                "of" => [
                  %{"name" => t.card, "type" => t.card},
                  %{"name" => t.quote, "type" => t.quote}
                ]
              },
              %{
                "name" => "tags",
                "type" => "arrayOf",
                "ordered" => true,
                "of" => %{"type" => "string"}
              },
              %{
                "name" => "hero",
                "type" => "image",
                "options" => %{"hotspot" => true},
                "fields" => [str.("alt")]
              },
              %{"name" => "gallery", "type" => "arrayOf", "of" => %{"type" => "image"}},
              %{"name" => "role", "type" => "codelist", "codelistId" => t.roles},
              %{"name" => "big", "type" => "codelist", "codelistId" => t.big},
              %{"name" => "subject", "type" => "codelist", "codelistId" => t.tree},
              %{
                "name" => "blurb",
                "type" => "localizedText",
                "languages" => ["eng", "nob"],
                "format" => "plain",
                "fallbackChain" => ["eng"]
              },
              %{
                "name" => "notes",
                "type" => "richText",
                "format" => "portableText",
                "blocks" => %{"of" => [%{"name" => t.quote}]}
              },
              %{"name" => "canvas", "type" => "richText", "editor" => "blocks"}
            ]
          }
        ] do
      {:ok, _} = Content.upsert_schema(schema, @dataset, scope)
    end

    for i <- 1..3, do: publish!(t.target, "#{t.target}-#{i}", "Target #{i}", %{}, scope)

    id = "w3t-doc-#{n}"

    publish!(
      t.struct,
      id,
      "Structured #{n}",
      %{
        "refs" => [
          %{"_ref" => "#{t.target}-1", "_type" => "reference", "_key" => "r00000000001"},
          %{"_ref" => "#{t.target}-2", "_type" => "reference", "_key" => "r00000000002"}
        ],
        "cards" => [
          %{"heading" => "Card one", "note" => "First"},
          %{"heading" => "Card two", "note" => "Second"}
        ],
        "sections" => [
          %{"_type" => t.card, "_key" => "aaaaaaaaaaa1", "heading" => "Sec card", "note" => "n"},
          %{
            "_type" => t.quote,
            "_key" => "aaaaaaaaaaa2",
            "quote" => "To be",
            "author" => "Hamlet"
          }
        ],
        "tags" => ["alpha", "beta", "gamma"],
        "role" => "A01",
        "big" => "C007",
        "subject" => "P2C3",
        "blurb" => %{"eng" => "Hello", "nob" => "Hei"},
        "notes" => [
          %{
            "_type" => "block",
            "_key" => "bbbbbbbbbbb1",
            "style" => "normal",
            "markDefs" => [],
            "children" => [
              %{
                "_type" => "span",
                "_key" => "ccccccccccc1",
                "text" => "Some notes",
                "marks" => []
              }
            ]
          },
          %{
            "_type" => t.quote,
            "_key" => "bbbbbbbbbbb2",
            "quote" => "Block quote",
            "author" => "Ann"
          }
        ]
      },
      scope
    )

    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: admin(conn), url: "#{base}/#{t.struct};#{id}", t: t, id: id, scope: scope}
  end

  defp publish!(type, id, title, content, scope) do
    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => id, "title" => title, "status" => "published", "content" => content},
        @dataset,
        scope
      )
  end

  defp admin(conn) do
    raw = "desk-editor-w3-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()

    {:ok, _} =
      Auth.create_token(raw, "desk-editor-w3", @dataset, ["read", "write", "admin"], ws.id)

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open!(conn, url) do
    {:ok, view, _html} = live(conn, url)
    render_async(view, 5_000)
    assert has_element?(view, ~s([data-pane-editing] #editor-form))
    view
  end

  # The saved value of `field` (the draft when there is one), polled until
  # `ok?` holds or the time is up; returns the last value read.
  defp saved(%{t: t, id: id, scope: scope}, field, ok?, tries \\ 25) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(t.struct, id, @dataset, scope)
    value = doc && (doc.content || %{})[field]

    cond do
      ok?.(value) -> value
      tries <= 0 -> value
      true -> Process.sleep(100) && saved(%{t: t, id: id, scope: scope}, field, ok?, tries - 1)
    end
  end

  defp change(view, name, value) do
    view
    |> form("#editor-form", %{name => value})
    |> render_change(%{"_target" => [name]})
  end

  defp array_btn(view, field, action, index) do
    view
    |> element(
      ~s([data-pane-editing] button[phx-value-action="#{action}"][phx-value-field="#{field}"][phx-value-index="#{index}"])
    )
    |> render_click()
  end

  test "J09 array of references: ▼ reorders, + Add and × save, in the desk pane", ctx do
    view = open!(ctx.conn, ctx.url)
    refs = fn v -> Enum.map(v || [], &(is_map(&1) && &1["_ref"])) end
    [t1, t2] = ["#{ctx.t.target}-1", "#{ctx.t.target}-2"]

    array_btn(view, "refs", "move_down", 0)
    assert refs.(saved(ctx, "refs", &(refs.(&1) == [t2, t1]))) == [t2, t1]

    view
    |> element(
      ~s([data-pane-editing] [data-field-name="refs"] > button[phx-value-action="add_row"])
    )
    |> render_click()

    assert has_element?(
             view,
             ~s([data-pane-editing] [data-field-name="refs"] li[data-row-index="2"] bp-reference-picker)
           )

    array_btn(view, "refs", "remove_row", 0)
    assert refs.(saved(ctx, "refs", &(refs.(&1) |> Enum.take(1) == [t1]))) |> Enum.take(1) == [t1]
  end

  test "J33 array of objects: an inline edit and a member added from the insert menu save, the preview names it",
       ctx do
    view = open!(ctx.conn, ctx.url)

    change(view, "doc[cards][1].heading", "Card two edited")

    assert saved(
             ctx,
             "cards",
             &(get_in(&1 || [], [Access.at(1), "heading"]) == "Card two edited")
           )
           |> Enum.at(1)
           |> Map.get("heading") == "Card two edited"

    view
    |> element(
      ~s([data-pane-editing] [data-field-name="sections"] button[data-member="#{ctx.t.quote}"])
    )
    |> render_click()

    assert has_element?(
             view,
             ~s([data-pane-editing] [data-field-name="sections"] li[data-member-type="#{ctx.t.quote}"][data-row-index="2"])
           )

    refute render(view) =~ "[object Object]"

    types = saved(ctx, "sections", &(length(&1 || []) == 3)) |> Enum.map(& &1["_type"])
    assert types == [ctx.t.card, ctx.t.quote, ctx.t.quote]
  end

  test "J34 array of strings: + Add, type, × and ▲ save in order", ctx do
    view = open!(ctx.conn, ctx.url)

    view
    |> element(
      ~s([data-pane-editing] [data-field-name="tags"] > button[phx-value-action="add_row"])
    )
    |> render_click()

    assert render(view) =~ ~s(name="doc[tags][3]")
    change(view, "doc[tags][3]", "delta")
    assert saved(ctx, "tags", &(&1 == ~w(alpha beta gamma delta))) == ~w(alpha beta gamma delta)

    array_btn(view, "tags", "remove_row", 0)
    array_btn(view, "tags", "move_up", 2)
    assert saved(ctx, "tags", &(&1 == ~w(beta delta gamma))) == ~w(beta delta gamma)
  end

  test "J12/J36 image: the picker's value (alt, focal point) saves; Remove clears it; an array of images takes a row",
       ctx do
    view = open!(ctx.conn, ctx.url)
    assert has_element?(view, ~s([data-pane-editing] bp-media-picker[hotspot]))

    value =
      Jason.encode!(%{
        "url" => "/media/files/w3t.png",
        "assetId" => Ecto.UUID.generate(),
        "alt" => "A red box",
        "focalX" => 0.25,
        "focalY" => 0.75,
        "width" => 24,
        "height" => 16
      })

    change(view, "doc[hero]", value)
    hero = saved(ctx, "hero", &(is_map(&1) and &1["alt"] == "A red box"))
    assert is_map(hero) and hero["alt"] == "A red box"
    assert inspect(hero) =~ "0.25"

    change(view, "doc[hero]", "")
    assert saved(ctx, "hero", &(&1 in [nil, "", %{}])) in [nil, "", %{}]

    view
    |> element(
      ~s([data-pane-editing] [data-field-name="gallery"] > button[phx-value-action="add_row"])
    )
    |> render_click()

    assert has_element?(
             view,
             ~s([data-pane-editing] [data-field-name="gallery"] li bp-media-picker)
           )
  end

  test "B05 flat codelists: the select and the searchable combobox save", ctx do
    view = open!(ctx.conn, ctx.url)

    assert has_element?(
             view,
             ~s([data-pane-editing] [data-field-name="big"] input[data-codelist-combobox])
           )

    change(view, "doc[role]", "B06")
    assert saved(ctx, "role", &(&1 == "B06")) == "B06"

    change(view, "doc[big]", "C042")
    assert saved(ctx, "big", &(&1 == "C042")) == "C042"
  end

  # Broken (in the plain Studio too): picking a code in the tree picker only
  # sets the component's own hidden input; no phx-change fires and the Classic
  # editor wires no :notify_id, so the pick is never saved (browser: p5-tree.mjs).
  @tag :desk_editor_red
  test "B05 tree codelist: picking a leaf saves it", ctx do
    view = open!(ctx.conn, ctx.url)

    view
    |> element(
      ~s([data-pane-editing] [data-field-name="subject"] [data-code="P2"] [phx-click="tree_node_select"])
    )
    |> render_click()

    assert has_element?(
             view,
             ~s([data-pane-editing] [data-field-name="subject"] input[data-tree-selected][value="P2"])
           )

    assert saved(ctx, "subject", &(&1 == "P2")) == "P2",
           "the tree picker showed P2 picked, but the document still holds the old code"
  end

  test "B06 localizedText: one language's input saves, the other keeps its value", ctx do
    view = open!(ctx.conn, ctx.url)
    change(view, "doc[blurb].nob", "Hei verden")

    assert saved(ctx, "blurb", &(&1 == %{"eng" => "Hello", "nob" => "Hei verden"})) ==
             %{"eng" => "Hello", "nob" => "Hei verden"}
  end

  test "rich text (Portable Text): typing saves, and the block dialog opens, saves by _key and closes on Escape",
       ctx do
    view = open!(ctx.conn, ctx.url)
    html = render(view)
    assert html =~ ~s(phx-hook="BarkparkPtBlocks")

    [current] =
      html |> Floki.parse_document!() |> Floki.attribute(~s(input[name="doc[notes]"]), "value")

    assert current =~ "Some notes"
    change(view, "doc[notes]", String.replace(current, "Some notes", "Some notes plus typed"))

    notes = saved(ctx, "notes", &(inspect(&1) =~ "plus typed"))
    assert inspect(notes) =~ "plus typed"

    assert Enum.any?(notes, &(&1["_key"] == "bbbbbbbbbbb2")),
           "the custom block survived the text edit"

    key = "bbbbbbbbbbb2"
    render_hook(view, "pt-block-open", %{"field" => "notes", "key" => key})

    assert has_element?(
             view,
             ~s([data-pane-editing] #bp-object-dialog[role="dialog"][data-object-key="#{key}"])
           )

    view |> element("#bp-object-dialog") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#bp-object-dialog")

    render_hook(view, "pt-block-open", %{"field" => "notes", "key" => key})

    view
    |> form("#bp-object-dialog-form-#{key}", %{"doc[__object].author" => "Ann Edited"})
    |> render_change(%{"_target" => ["doc[__object].author"]})

    view |> form("#bp-object-dialog-form-#{key}") |> render_submit()
    refute has_element?(view, "#bp-object-dialog")

    block = fn v -> Enum.find(v || [], &(&1["_key"] == key)) || %{} end

    assert block.(saved(ctx, "notes", &(block.(&1)["author"] == "Ann Edited")))["author"] ==
             "Ann Edited"
  end

  test "rich text (editor: blocks): the canvas mounts and its ops save", ctx do
    view = open!(ctx.conn, ctx.url)
    html = render(view)
    assert html =~ ~s(phx-hook="BarkparkFieldCanvas")

    [rev] =
      html
      |> Floki.parse_document!()
      |> Floki.attribute(~s([phx-hook="BarkparkFieldCanvas"]), "data-document-rev")

    render_hook(view, "field-block-ops", %{
      "field" => "canvas",
      "if_rev" => rev,
      "ops" => [
        %{
          "op" => "append-block",
          "block" => %{
            "id" => "c-1-w3t",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Canvas words"}]
          }
        }
      ]
    })

    assert inspect(saved(ctx, "canvas", &(inspect(&1) =~ "Canvas words"))) =~ "Canvas words"
  end
end
