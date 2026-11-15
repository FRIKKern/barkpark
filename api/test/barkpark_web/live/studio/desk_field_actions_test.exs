defmodule BarkparkWeb.Studio.DeskFieldActionsTest do
  @moduledoc """
  A field's "Field actions" menu on the desk (`Desk.FieldActions`), as the
  TanStack Studio's (`Fields.tsx` `FieldActions`): the "…" button opens a
  menu with "Copy field" and "Paste field". Copy answers with the field's
  stored value in the TanStack Studio's clipboard format (`Desk.FieldClip`);
  the browser writes the clipboard (`__desk_field_actions.test.mjs`). An
  empty field is refused. Paste: `desk_field_paste_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.FieldClip

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "factions_#{n}"
    f = fn name, t, extra -> Map.merge(%{"name" => name, "title" => name, "type" => t}, extra) end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Actions #{type}",
          "visibility" => "public",
          "fields" => [
            f.("title", "string", %{}),
            f.("excerpt", "text", %{}),
            f.("count", "number", %{}),
            f.("empty", "string", %{}),
            f.("blank", "string", %{}),
            f.("hidden", "string", %{
              "visibleWhen" => %{"field" => "excerpt", "operator" => "eq", "value" => "show it"}
            }),
            f.("tags", "arrayOf", %{"of" => [%{"type" => "string"}]}),
            f.("cta", "composite", %{"fields" => [%{"name" => "url", "type" => "string"}]})
          ]
        },
        @dataset
      )

    id = "factions-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Here",
          "excerpt" => "Short <excerpt> & more.",
          "count" => 3,
          "blank" => "",
          "hidden" => "not shown",
          "tags" => ["a", "b"],
          "cta" => %{"url" => "https://example.com"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-factions-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-factions", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     id: id,
     desk: "#{root}/_desk/#{type};#{id}",
     list: "#{root}/_desk/#{type}"}
  end

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  @menu ~s([data-pane-editing] #editor-form #field-actions-menu)

  # The form's one menu; the browser names the field as the item is pressed.
  defp copy(view, name) do
    view
    |> element(~s(#{@menu} button[data-desk-field-copy]))
    |> render_click(%{"field" => name})
  end

  test "each field's button opens the form's one menu, with Copy field and Paste field", c do
    view = desk(c)

    for name <- ~w(title excerpt count empty blank tags cta) do
      button =
        ~s|#{@form} .field:has([id^="#{name}"]) > .field-actions > button.icon-btn[type="button"][aria-label="Field actions"]|

      assert has_element?(
               view,
               ~s|#{button}[id="field-actions-#{name}-button"][popovertarget="field-actions-menu"][aria-haspopup="menu"][aria-expanded="false"][data-desk-field="#{name}"]:not([disabled]):not([data-desk-paste-off])|
             ),
             name
    end

    # One menu, not one per field. bp-desk.js gives a `dk-doc-menu-list`
    # popover its keys.
    html = view |> element(@form) |> render()
    assert length(Regex.scan(~r/\srole="menu"/, html)) == 1

    assert has_element?(
             view,
             ~s(#{@menu}[popover][role="menu"].dk-doc-menu-list.dk-menu[aria-label="Field actions"])
           )

    items =
      for [_, attrs, words] <-
            Regex.scan(
              ~r/<button([^>]*\srole="menuitem"[^>]*)>([^<]*)</,
              view |> element(@menu) |> render()
            ) do
        {String.trim(words), attrs =~ ~r/\sdisabled[\s=>]|\sdisabled$/}
      end

    assert items == [{"Copy field", false}, {"Paste field", false}]
  end

  # 40 fields drew 40 menus: about 2.7 KB a field. A field now carries its
  # button only.
  test "a field carries its button, not a menu: under 500 bytes of field actions each", c do
    view = desk(c)

    for name <- ~w(title excerpt tags cta) do
      actions =
        view |> element(~s|#{@form} .field:has([id^="#{name}"]) > .field-actions|) |> render()

      assert byte_size(actions) < 500, "#{name}: #{byte_size(actions)} bytes"
      refute actions =~ "menuitem"
    end
  end

  test "Copy field answers with the stored value in the TanStack clipboard format", c do
    view = desk(c)
    copy(view, "excerpt")

    assert_push_event(view, "desk:field-copied", %{
      field: "excerpt",
      json: json,
      html: html,
      text: text
    })

    assert text == "Short <excerpt> & more."

    assert %{
             "type" => "sanityClipboardItem",
             "isDocument" => false,
             "documentId" => id,
             "documentType" => type,
             "schemaTypeName" => "string",
             "valuePath" => ["excerpt"],
             "value" => "Short <excerpt> & more.",
             "patchType" => "replace",
             "barkpark" => %{
               "kind" => "field",
               "field" => %{
                 "name" => "excerpt",
                 "sig" => "string",
                 "value" => "Short <excerpt> & more."
               }
             }
           } = Jason.decode!(json)

    assert {id, type} == {c.id, c.type}

    # text/html carries the same item, base64, around the escaped words.
    assert [_, b64] = Regex.run(~r/^<div data-sanity-clipboard-base64="([^"]+)"><p>/, html)
    assert Base.decode64!(b64) == json
    assert html =~ "<p>Short &lt;excerpt&gt; &amp; more.</p></div>"
  end

  test "each kind copies under its signature: title, number, list, object", c do
    view = desk(c)

    for {name, sig, value, text} <- [
          {"title", "string", "Here", "Here"},
          {"count", "number", 3, "3"},
          {"tags", "array:string", ["a", "b"], "a, b"},
          {"cta", "object:url=string", %{"url" => "https://example.com"}, "https://example.com"}
        ] do
      copy(view, name)
      assert_push_event(view, "desk:field-copied", %{field: ^name, json: json, text: ^text})

      assert %{"barkpark" => %{"field" => %{"sig" => ^sig, "value" => ^value}}} =
               Jason.decode!(json)
    end
  end

  test "an empty field is refused in words and nothing is handed over", c do
    view = desk(c)
    copy(view, "empty")

    assert_push_event(
      view,
      "desk:field-copied",
      %{field: "empty", empty: "Empty value, nothing to copy"} = answer
    )

    refute Map.has_key?(answer, :json)
    refute Map.has_key?(answer, :text)
  end

  # Sanity's isEmptyValue, as TanStack's: a cleared text is a value.
  test "an empty text copies; only nothing, an empty list and a lone _key are empty", c do
    view = desk(c)
    copy(view, "blank")
    assert_push_event(view, "desk:field-copied", %{field: "blank", json: json, text: ""})
    assert %{"value" => "", "barkpark" => %{"field" => %{"value" => ""}}} = Jason.decode!(json)
  end

  test "a field the form hides (visibleWhen) is not answered for, whatever the page sent", c do
    view = desk(c)
    refute has_element?(view, ~s(#{@form} [id="field-actions-hidden-button"]))

    render_hook(view, "desk-field-copy", %{"field" => "hidden"})
    refute_push_event(view, "desk:field-copied", _, 50)
  end

  test "aria-expanded is the browser's: a patch of the form leaves an open menu's alone", c do
    view = desk(c)
    button = view |> element(~s(#{@form} [id="field-actions-title-button"])) |> render()

    assert [_, mounted] = Regex.run(~r/phx-mounted="([^"]+)"/, button)
    assert mounted =~ "ignore_attrs"
    assert mounted =~ "aria-expanded"
  end

  # When a rule hides the field under its open menu and no field is left to
  # take the focus, bp-desk-field-actions.js puts it on the pane's selected
  # view tab. That works only while the SERVER draws the tab focusable: a
  # tabindex the script added would go with the next patch.
  test "the edit pane's selected view tab is focusable as the server draws it", c do
    view = desk(c)

    assert has_element?(
             view,
             ~s([data-pane-editing] .view-tabs [role="tab"][aria-selected="true"][tabindex="0"])
           )

    refute view |> element("[data-pane-editing] #editor-form") |> render() =~
             ~r/^<form[^>]*\stabindex=/
  end

  test "a field the schema does not have, or no open document, is answered with nothing", c do
    view = desk(c)

    for params <- [%{"field" => "nope"}, %{"field" => "_rev"}, %{"field" => 1}, %{}] do
      render_hook(view, "desk-field-copy", params)
    end

    refute_push_event(view, "desk:field-copied", _, 50)

    {:ok, list, _html} = live(c.conn, c.list)
    render_hook(list, "desk-field-copy", %{"field" => "title"})
    render_hook(list, "desk-field-nope", %{"field" => "title"})
    refute_push_event(list, "desk:field-copied", _, 50)
  end

  test "the button is drawn under the pointer or the focus, and always where nothing hovers" do
    doc = BarkparkWeb.Studio.Desk.DocStyle.sheet(%{}) |> rendered_to_string()
    desk = BarkparkWeb.Studio.Desk.Style.sheet(%{}) |> rendered_to_string()

    assert doc =~
             ".dk .dk-edit .field > .field-actions { position: absolute; top: 0; right: 25px; z-index: 2; opacity: 0; }"

    assert doc =~
             ".dk .dk-edit .field:is(:hover, :focus-within):not(:has(.field:is(:hover, :focus-within))) > .field-actions, .dk .dk-edit .field > .field-actions:focus-within, .dk .dk-edit .field > .field-actions:has(> [aria-expanded=\"true\"]) { opacity: 1; }"

    assert doc =~ "@media (hover: none) { .dk .dk-edit .field > .field-actions { opacity: 1; } }"
    assert doc =~ ".dk .dk-edit .field-actions > .icon-btn { width: 44px; height: 44px; }"
    # The rule that kept the placeholder out of reach is gone.
    refute desk =~ "pointer-events: none; }\n      .dk-search-dialog"
    refute desk =~ ".field > .field-actions"
  end

  test "the desk names the browser script by its content hash; the root layout does not link it",
       c do
    {:ok, _view, html} = live(c.conn, c.desk)
    path = BarkparkWeb.StaticAssets.path("bp-desk-field-actions.js")

    assert path =~ ~r|^/assets/v/[\w-]{16}/bp-desk-field-actions\.js$|
    assert html =~ ~s(data-desk-field-actions="#{path}")
    refute html =~ ~r/<script[^>]*bp-desk-field-actions/
  end

  test "the menu is drawn for a named field only" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <BarkparkWeb.Studio.Desk.FieldSlots.slots field={%{"type" => "string"}} />
      <BarkparkWeb.Studio.Desk.FieldSlots.slots field={true} />
      """)

    refute html =~ "field-actions"
    assert length(String.split(html, ~s(class="change-bar"))) == 3
  end

  describe "FieldClip" do
    test "a signature is the type reduced to what decides a fit" do
      for type <- ~w(string text url email select),
          do: assert(FieldClip.sig(%{"type" => type}) == "string")

      assert FieldClip.sig(%{"type" => "number"}) == "number"
      assert FieldClip.sig(%{"type" => "reference", "refType" => "author"}) == "reference:author"
      assert FieldClip.sig(%{"type" => "reference"}) == "reference:?"
      assert FieldClip.sig(%{"type" => "arrayOf", "of" => %{"type" => "text"}}) == "array:string"

      assert FieldClip.sig(%{"type" => "arrayOf", "of" => [%{"type" => "number"}]}) ==
               "array:number"

      assert FieldClip.sig(%{"type" => "arrayOf"}) == "array:?"

      assert FieldClip.sig(%{
               "type" => "composite",
               "fields" => [
                 %{"name" => "b", "type" => "number"},
                 %{"name" => "a", "type" => "url"}
               ]
             }) == "object:a=string,b=number"

      assert FieldClip.sig(%{}) == "?"
    end

    test "empty is nothing, an empty list, or an object with only its _key (clipboard.ts isEmpty)" do
      for value <- [nil, [], %{"_key" => "k"}], do: assert(FieldClip.empty?(value))

      for value <- ["", %{}, false, 0, "a", [nil], %{"a" => nil}],
          do: refute(FieldClip.empty?(value))
    end

    test "the words leave out keys that start with an underscore" do
      assert FieldClip.as_text(%{"_type" => "x", "b" => 2, "a" => ["one", nil, %{"c" => true}]}) ==
               "one, true, 2"
    end
  end
end
