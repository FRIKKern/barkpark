defmodule BarkparkWeb.Studio.DeskEditorStructuredTest do
  @moduledoc """
  The desk's editor pane (the last document of a desk chain is edited by the
  Studio's own editor, `DeskLive` → `StudioLive`) with structured fields:
  arrays of references, objects and strings, multi-type arrays, images, an
  array of images, codelists (flat, combobox, tree), localizedText, Portable
  Text with its block dialog, and a block-canvas richText field.

  Probed in a real browser first (editing lane, worker w3): every one of these
  behaves the same in the desk pane as in the plain Studio. These tests pin
  that for the split refactor. The tree codelist (`subject`) is seeded but not
  pinned here: picking a node does not save in the plain Studio either, so it
  is the Studio's defect, not the desk's (the red test stays on branch
  `editing/probe`).
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

  # Poll the view for a condition instead of asserting right after a send.
  defp poll(view, fun, tries \\ 25) do
    render_async(view, 5_000)

    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  # One attribute of the first element `selector` matches in the rendered page.
  defp attr(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  # A Web Component field (bp-media-picker, bp-rich-text-editor) keeps its
  # value in a hidden `doc[<field>]` input. In the browser the component emits
  # `bp-change`; BarkparkFieldBridge writes the value into that hidden input
  # and dispatches `input`, so the form's phx-change="autosave" posts the
  # WHOLE form with the new value. LiveViewTest refuses to set a hidden input
  # through form/3, so the value rides in render_change/2's params, which are
  # merged over the form's own values: the same payload the bridge sends.
  defp bridge(view, field, value) do
    view
    |> form("#editor-form")
    |> render_change(%{"doc" => %{field => value}, "_target" => ["doc", field]})
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

    assert poll(view, fn ->
             has_element?(
               view,
               ~s([data-pane-editing] [data-field-name="refs"] li[data-row-index="2"] bp-reference-picker)
             )
           end),
           "+ Add drew no third reference row"

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

    assert poll(view, fn ->
             has_element?(
               view,
               ~s([data-pane-editing] [data-field-name="sections"] li[data-member-type="#{ctx.t.quote}"][data-row-index="2"])
             )
           end),
           "the insert menu drew no quote row"

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

    assert poll(view, fn -> render(view) =~ ~s(name="doc[tags][3]") end),
           "+ Add drew no fourth tag input"

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

    # The browser action: pick an asset in bp-media-picker, type its alt text
    # and drag the focal point; the picker emits the value through the bridge.
    bridge(view, "hero", value)
    hero = saved(ctx, "hero", &(is_map(&1) and &1["alt"] == "A red box"))
    assert is_map(hero) and hero["alt"] == "A red box"
    assert hero["focalX"] == 0.25 and hero["focalY"] == 0.75

    # The picker's Remove: the bridge posts an empty value.
    bridge(view, "hero", "")
    assert saved(ctx, "hero", &(&1 in [nil, "", %{}])) in [nil, "", %{}]

    view
    |> element(
      ~s([data-pane-editing] [data-field-name="gallery"] > button[phx-value-action="add_row"])
    )
    |> render_click()

    assert poll(view, fn ->
             has_element?(
               view,
               ~s([data-pane-editing] [data-field-name="gallery"] li bp-media-picker)
             )
           end),
           "+ Add drew no image row in the gallery"
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

  test "B06 localizedText: one language's input saves, the other keeps its value", ctx do
    view = open!(ctx.conn, ctx.url)
    change(view, "doc[blurb].nob", "Hei verden")

    assert saved(ctx, "blurb", &(&1 == %{"eng" => "Hello", "nob" => "Hei verden"})) ==
             %{"eng" => "Hello", "nob" => "Hei verden"}
  end

  test "rich text (Portable Text): typing saves, and the block dialog opens, saves by _key and closes on Escape",
       ctx do
    view = open!(ctx.conn, ctx.url)
    assert render(view) =~ ~s(phx-hook="BarkparkPtBlocks")
    current = attr(view, ~s([data-pane-editing] input[name="doc[notes]"]), "value")

    assert current =~ "Some notes"
    # The browser action: typing in bp-rich-text-editor, which emits the
    # whole Portable Text value through the bridge.
    bridge(view, "notes", String.replace(current, "Some notes", "Some notes plus typed"))

    notes = saved(ctx, "notes", &(inspect(&1) =~ "plus typed"))
    assert inspect(notes) =~ "plus typed"

    assert Enum.any?(notes, &(&1["_key"] == "bbbbbbbbbbb2")),
           "the custom block survived the text edit"

    key = "bbbbbbbbbbb2"
    dialog = ~s([data-pane-editing] #bp-object-dialog[role="dialog"][data-object-key="#{key}"])
    render_hook(view, "pt-block-open", %{"field" => "notes", "key" => key})
    assert poll(view, fn -> has_element?(view, dialog) end), "the block dialog did not open"

    view |> element("#bp-object-dialog") |> render_keydown(%{"key" => "Escape"})

    assert poll(view, fn -> not has_element?(view, "#bp-object-dialog") end),
           "Escape left the block dialog open"

    render_hook(view, "pt-block-open", %{"field" => "notes", "key" => key})
    assert poll(view, fn -> has_element?(view, dialog) end), "the block dialog did not reopen"

    view
    |> form("#bp-object-dialog-form-#{key}", %{"doc[__object].author" => "Ann Edited"})
    |> render_change(%{"_target" => ["doc[__object].author"]})

    view |> form("#bp-object-dialog-form-#{key}") |> render_submit()

    assert poll(view, fn -> not has_element?(view, "#bp-object-dialog") end),
           "Save left the block dialog open"

    block = fn v -> Enum.find(v || [], &(&1["_key"] == key)) || %{} end

    assert block.(saved(ctx, "notes", &(block.(&1)["author"] == "Ann Edited")))["author"] ==
             "Ann Edited"
  end

  test "rich text (editor: blocks): the canvas mounts and its ops save", ctx do
    view = open!(ctx.conn, ctx.url)
    assert render(view) =~ ~s(phx-hook="BarkparkFieldCanvas")

    rev =
      attr(view, ~s([data-pane-editing] [phx-hook="BarkparkFieldCanvas"]), "data-document-rev")

    assert is_binary(rev), "the canvas carries no data-document-rev"

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

  # A 4x4 red PNG, built here so the test carries no fixture file.
  defp png do
    chunk = fn type, data ->
      <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
    end

    row = <<0>> <> :binary.copy(<<220, 30, 30>>, 4)

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk.("IHDR", <<4::32, 4::32, 8, 2, 0, 0, 0>>) <>
      chunk.("IDAT", :zlib.compress(:binary.copy(row, 4))) <> chunk.("IEND", <<>>)
  end

  # The Studio's LiveView upload (`allow_upload(:image)` in StudioLive's mount,
  # the legacy image-picker modal). No field opens this modal any more (the
  # image field is <bp-media-picker>, which uploads over HTTP), so this is the
  # only place the desk's `allow_upload` is exercised: open, upload, consume,
  # and the saved value.
  test "J12 LiveView upload (legacy image picker): the upload completes in the desk and the value saves",
       ctx do
    view = open!(ctx.conn, ctx.url)
    render_hook(view, "open-image-picker", %{"field" => "hero"})

    assert poll(view, fn ->
             has_element?(view, ~s(#image-picker-dialog[role="dialog"] form#upload-form))
           end),
           "the legacy image picker did not open"

    upload =
      file_input(view, "#upload-form", :image, [
        %{name: "w3t-red.png", content: png(), type: "image/png"}
      ])

    assert render_upload(upload, "w3t-red.png") =~ "image-upload-entry"
    view |> form("#upload-form") |> render_submit()

    assert poll(view, fn -> not has_element?(view, "#image-picker-dialog") end),
           "the image picker stayed open after the upload was submitted"

    hero = saved(ctx, "hero", &(inspect(&1) =~ "w3t-red"))

    assert inspect(hero) =~ "w3t-red",
           "the uploaded file never reached the saved value: #{inspect(hero)}"
  end
end
