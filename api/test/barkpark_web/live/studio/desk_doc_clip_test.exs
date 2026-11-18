defmodule BarkparkWeb.Studio.DeskDocClipTest do
  @moduledoc """
  "Copy document" and "Paste document" in the desk's header "…" menu
  (`Desk.DocClip`), as the TanStack Studio's (`DocHeaderMenu.tsx`): the
  copy is Sanity's document item with each field's signature; a paste
  fills every field of the open document whose copied value fits, and only
  the fields this editor may write, and leaves the rest alone.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @form "[data-pane-editing] #editor-form"
  @menu ~s([data-pane-editing] [role="menu"][id$="-editor-actions"])
  @copied "desk:doc-copied"
  @toast "desk:field-toast"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "dclip_#{n}"
    author = "dcauthor_#{n}"
    f = fn name, t, extra -> Map.merge(%{"name" => name, "title" => name, "type" => t}, extra) end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => author,
          "visibility" => "public",
          "fields" => [f.("title", "string", %{})]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Clip #{type}",
          "visibility" => "public",
          "fields" => [
            f.("title", "string", %{}),
            f.("excerpt", "text", %{}),
            f.("count", "number", %{}),
            f.("choice", "select", %{"options" => ["a", "b", "c"]}),
            f.("reviewer", "reference", %{"refType" => author}),
            f.("seo", "composite", %{
              "fields" => [
                %{"name" => "metaTitle", "type" => "string"},
                %{"name" => "metaDescription", "type" => "text"}
              ]
            }),
            f.("tags", "arrayOf", %{"of" => [%{"type" => "string"}]}),
            f.("fixed", "string", %{
              "readOnly" => %{"field" => "choice", "operator" => "eq", "value" => "b"}
            }),
            f.("hidden", "string", %{
              "visibleWhen" => %{"field" => "excerpt", "operator" => "eq", "value" => "show it"}
            })
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(author, %{"doc_id" => "dca-#{n}", "title" => "Ada"}, @dataset)

    from = "dclip-from-#{n}"
    to = "dclip-to-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => from,
          "title" => "Source title",
          "excerpt" => "Source excerpt",
          "count" => 3,
          "choice" => "a",
          "reviewer" => "dca-#{n}",
          "seo" => %{"metaTitle" => "Meta", "metaDescription" => "Fixture SEO."},
          "tags" => ["one", "two"],
          "fixed" => "source fixed",
          "hidden" => "source hidden"
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => to,
          "title" => "Target title",
          "excerpt" => "Target excerpt",
          "count" => 9,
          "choice" => "b",
          "fixed" => "locked while choice is b",
          "hidden" => "target hidden"
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-dclip-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-dclip", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok,
     conn: conn,
     type: type,
     from: from,
     to: to,
     author: "dca-#{n}",
     at: fn id -> "#{root}/#{type};#{id}" end}
  end

  defp open(c, id) do
    {:ok, view, _html} = live(c.conn, c.at.(id))
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp pressed(view, params),
    do: Map.merge(Map.take(BarkparkWeb.EditorPost.marks(view), ["_bp_doc"]), params)

  defp paste(view, clip),
    do: render_hook(view, "desk-doc-paste", pressed(view, %{"clip" => clip}))

  defp copy(c, id) do
    view = open(c, id)
    render_hook(view, "desk-doc-copy", %{})
    assert_push_event(view, @copied, %{json: json, html: html, text: text})
    %{json: json, html: html, text: text}
  end

  defp stored(c, id) do
    doc =
      case Content.get_document(DraftId.draft_id(id), c.type, @dataset) do
        {:ok, draft} -> draft
        _ -> elem(Content.get_document(id, c.type, @dataset), 1)
      end

    Map.put(doc.content, "title", doc.title)
  end

  # What a paste changed: `{field => {before, after}}`.
  defp changes(c, view, clip) do
    before = stored(c, c.to)
    paste(view, clip)
    now = stored(c, c.to)

    for key <- Enum.uniq(Map.keys(before) ++ Map.keys(now)),
        Map.fetch(before, key) != Map.fetch(now, key),
        into: %{},
        do: {key, {before[key], now[key]}}
  end

  defp doc_clip(fields) do
    Jason.encode!(%{
      "type" => "sanityClipboardItem",
      "isDocument" => true,
      "value" => %{},
      "barkpark" => %{"kind" => "document", "docType" => "x", "fields" => fields}
    })
  end

  describe "the header menu" do
    test "ends with Copy document and Paste document, under a line, before Delete", c do
      view = open(c, c.to)
      menu = view |> element(@menu) |> render()

      names =
        Regex.scan(~r/data-desk-doc-action="([^"]+)"/, menu) |> Enum.map(&List.last/1)

      at = Enum.find_index(names, &(&1 == "delete-doc"))
      assert ["copy-document", "paste-document", "delete-doc"] == Enum.slice(names, (at - 2)..at)
      assert menu =~ "Copy document"
      assert menu =~ "Paste document"

      assert has_element?(
               view,
               ~s(#{@menu} button[data-desk-doc-copy][phx-click="desk-doc-copy"])
             )

      assert has_element?(
               view,
               ~s(#{@menu} button[data-desk-doc-paste][phx-click="desk-doc-paste"][data-desk-nothing="Nothing to paste"])
             )

      # The line before Copy document.
      assert menu =~ ~r/<hr[^>]*>\s*<button[^>]*data-desk-doc-action="copy-document"/
      # The footer's menu has neither.
      refute has_element?(view, ~s([id$="-footer-actions"] [data-desk-doc-copy]))
    end

    test "the page loads the script that writes and reads the clipboard", c do
      view = open(c, c.to)
      assert has_element?(view, ~s(#desk-panes[data-desk-doc-clip*="bp-desk-doc-clip"]))
    end
  end

  describe "Copy document" do
    test "puts Sanity's document item on the clipboard, each field with its signature", c do
      %{json: json, html: html, text: text} = copy(c, c.from)
      item = Jason.decode!(json)

      assert %{
               "type" => "sanityClipboardItem",
               "isDocument" => true,
               "documentId" => from,
               "documentType" => type,
               "schemaTypeName" => type,
               "valuePath" => [],
               "patchType" => "replace"
             } = item

      assert from == c.from and type == c.type
      assert item["value"]["_type"] == c.type
      assert item["value"]["excerpt"] == "Source excerpt"
      sigs = Map.new(item["barkpark"]["fields"], &{&1["name"], &1["sig"]})

      assert sigs["title"] == "string"
      assert sigs["count"] == "number"

      assert sigs["reviewer"] ==
               "reference:" <> "dcauthor_" <> String.replace(c.type, "dclip_", "")

      assert sigs["seo"] == "object:metaDescription=string,metaTitle=string"
      assert sigs["tags"] == "array:string"
      # The words: every value, in the schema's order.
      assert text =~ "Source title, Source excerpt, 3"
      assert text =~ "Fixture SEO."
      assert html =~ ~s(data-sanity-clipboard-base64="#{Base.encode64(json)}")
    end

    test "an empty document is refused with Sanity's words", c do
      {:ok, _} = Content.create_document(c.type, %{"doc_id" => "#{c.to}-empty"}, @dataset)
      view = open(c, "#{c.to}-empty")
      render_hook(view, "desk-doc-copy", %{})
      assert_push_event(view, @copied, %{empty: "Empty value, nothing to copy"})
    end

    test "is a read and Paste document a write in the capability gate" do
      assert Caps.classify("desk-doc-copy") == :read
      assert Caps.classify("desk-doc-paste") == :write
    end
  end

  describe "Paste document" do
    test "fills every field the copy fits, and leaves locked, hidden and unfitting ones", c do
      %{json: json} = copy(c, c.from)
      view = open(c, c.to)

      changed = changes(c, view, json)

      assert changed["title"] == {"Target title", "Source title"}
      assert changed["excerpt"] == {"Target excerpt", "Source excerpt"}
      assert changed["count"] == {9, 3}
      assert changed["tags"] == {nil, ["one", "two"]}
      assert {_, %{"metaTitle" => "Meta", "metaDescription" => "Fixture SEO."}} = changed["seo"]
      assert {_, ref} = changed["reviewer"]
      assert ref == c.author or match?(%{"_ref" => _}, ref)
      # `choice` was b and the copy's a: written, while `fixed` was locked by b
      # when the paste was planned, and `hidden` is not shown.
      assert changed["choice"] == {"b", "a"}
      refute Map.has_key?(changed, "fixed")
      refute Map.has_key?(changed, "hidden")
    end

    test "writes only the schema's own fields: no system key, nothing it does not declare", c do
      view = open(c, c.to)

      clip =
        doc_clip([
          %{"name" => "excerpt", "sig" => "string", "value" => "Pasted"},
          %{"name" => "_id", "sig" => "string", "value" => "evil"},
          %{"name" => "_type", "sig" => "string", "value" => "evil"},
          %{"name" => "_rev", "sig" => "string", "value" => "evil"},
          %{"name" => "undeclared", "sig" => "string", "value" => "evil"},
          %{"name" => "count", "sig" => "string", "value" => "not a number"},
          %{"name" => "choice", "sig" => "string", "value" => "z"}
        ])

      assert changes(c, view, clip) == %{"excerpt" => {"Target excerpt", "Pasted"}}
      {:ok, draft} = Content.get_document(DraftId.draft_id(c.to), c.type, @dataset)
      assert draft.type == c.type
    end

    test "a copy where nothing fits is refused in Sanity's words and writes nothing", c do
      view = open(c, c.to)
      clip = doc_clip([%{"name" => "count", "sig" => "string", "value" => "x"}])

      assert changes(c, view, clip) == %{}

      assert_push_event(view, @toast, %{
        tone: "critical",
        title: "Invalid clipboard item",
        description: "Source and target schema types are not compatible"
      })
    end

    test "a copied field is not a document: nothing to paste", c do
      view = open(c, c.to)

      clip =
        Jason.encode!(%{
          "type" => "sanityClipboardItem",
          "isDocument" => false,
          "schemaTypeName" => "string",
          "value" => "x",
          "barkpark" => %{
            "kind" => "field",
            "field" => %{"name" => "excerpt", "sig" => "string", "value" => "x"}
          }
        })

      assert changes(c, view, clip) == %{}
      assert_push_event(view, @toast, %{tone: "default", title: "Nothing to paste"})
      assert changes(c, view, "not json") == %{}
    end

    test "Sanity's own document item pastes its texts and numbers", c do
      view = open(c, c.to)

      clip =
        Jason.encode!(%{
          "type" => "sanityClipboardItem",
          "isDocument" => true,
          "documentType" => "post",
          "value" => %{
            "_id" => "evil",
            "_type" => "post",
            "excerpt" => "From Sanity",
            "count" => 5
          }
        })

      assert changes(c, view, clip) == %{
               "excerpt" => {"Target excerpt", "From Sanity"},
               "count" => {9, 5}
             }
    end

    test "pressed in another document's form, it writes nothing", c do
      %{json: json} = copy(c, c.from)
      view = open(c, c.to)
      before = stored(c, c.to)

      render_hook(view, "desk-doc-paste", %{
        "clip" => json,
        PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.from)
      })

      render_hook(view, "desk-doc-paste", %{"clip" => json})
      assert stored(c, c.to) == before
    end
  end
end
