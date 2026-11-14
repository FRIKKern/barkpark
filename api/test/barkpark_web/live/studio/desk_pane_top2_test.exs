defmodule BarkparkWeb.Studio.DeskPaneTop2Test do
  @moduledoc """
  LOOKS "doc pane top 2": the edit pane's top as the TanStack Studio draws it
  (`DocumentPane.tsx`), measured against the re-shoot pairs.

    * (a) no row of reference links over the form; each reference is in
      the "…" menu, "Open reference: <title>", a patch to the next pane;
    * (b) a title bar under the header: the title, then Editor and JSON
      tabs, JSON opening Inspect;
    * (d) no rule under the header;
    * (e) the others in the document as an avatar stack, not dots;
    * (f) the header's icons in TanStack's order: Share, "…", Split,
      Focus, close;
    * (g) the footer's Publish carries TanStack's upload arrow.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.DocStatus

  @dataset "production"
  @pane "section[data-pane-editing]"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "pt2_author_#{n}"
    post = "pt2_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "Authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "Posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]}
          ]
        },
        @dataset
      )

    ada = "pt2-ada-#{n}"
    one = "pt2-post-#{n}"

    {:ok, _} =
      Content.create_document(author, %{"doc_id" => ada, "title" => "Ada Lovelace"}, @dataset)

    {:ok, _} =
      Content.create_document(
        post,
        %{
          "doc_id" => one,
          "title" => "Post One",
          "content" => %{"author" => %{"_ref" => ada, "_type" => "reference"}}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-pt2-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-pt2",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: conn, base: base, author: author, post: post, ada: ada, one: one}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.post};#{c.one}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # ── (a) ───────────────────────────────────────────────────────────────────

  test "(a) no row of reference links; the reference is in the menu, before Delete", c do
    view = open(c)
    refute has_element?(view, "#{@pane} nav.dk-edit-refs")
    refute has_element?(view, "#{@pane} > nav")

    to = "#{c.base}/#{c.post};#{c.one};#{c.ada},type=#{c.author},parentRefPath=author"
    menu = ~s(#{@pane} > .pane-header [role="menu"][id$="-actions"])

    assert has_element?(
             view,
             ~s(#{menu} a[role="menuitem"][data-desk-doc-action="open-reference"][href="#{to}"][data-phx-link="patch"]),
             "Open reference: Ada Lovelace"
           )

    names =
      Regex.scan(~r/data-desk-doc-action="([^"]+)"/, view |> element(menu) |> render())
      |> Enum.map(&List.last/1)

    at = Enum.find_index(names, &(&1 == "open-reference"))
    assert at != nil
    assert Enum.find_index(names, &(&1 == "delete-doc")) == at + 1

    # The footer's menu is the document's actions only.
    refute has_element?(
             view,
             ~s(#{@pane} [id$="-footer-actions"] [data-desk-doc-action="open-reference"])
           )

    view |> element(~s(#{menu} a[data-desk-doc-action="open-reference"])) |> render_click()
    assert_patch(view, to)
  end

  # ── (b) ───────────────────────────────────────────────────────────────────

  test "(b) a title bar under the header: the title, then Editor and JSON; JSON opens Inspect",
       c do
    view = open(c)
    bar = "#{@pane} > .doc-title-bar[id]"

    assert has_element?(view, "#{bar} .title-row .title", "Post One")

    assert has_element?(
             view,
             ~s(#{bar} [role="tablist"] [role="tab"][aria-selected="true"]),
             "Editor"
           )

    assert has_element?(
             view,
             ~s(#{bar} [role="tab"][aria-selected="false"][data-desk-json-tab]),
             "JSON"
           )

    view |> element("#{bar} [data-desk-json-tab]") |> render_click()
    assert_patch(view, "#{c.base}/#{c.post};#{c.one},inspect=on")
    render_async(view, 5_000)
    assert has_element?(view, "#{@pane} dialog")
  end

  test "(b) the title bar's look is TanStack's: 85 px with its tabs, 13 px 600" do
    css = rendered_to_string(BarkparkWeb.Studio.Desk.DocStyle.sheet(%{}))
    assert css =~ ".dk .dk-edit > .doc-title-bar { box-sizing: border-box; height: 50px;"
    assert css =~ "font-size: 13px; line-height: 19px; font-weight: 600;"
    assert css =~ ".dk .dk-edit > .doc-title-bar:has(.view-tabs) { height: 85px;"
  end

  # ── (d) ───────────────────────────────────────────────────────────────────

  test "(d) no rule under the document pane's header" do
    css = rendered_to_string(BarkparkWeb.Studio.Desk.Style.sheet(%{}))
    assert css =~ ~r/\.dk \.dk-doc > \.pane-header \{[^}]*border-bottom: 0;/
  end

  # ── (e) ───────────────────────────────────────────────────────────────────

  test "(e) the others in the document are avatars: initials on their colour, you left out" do
    doc = %{doc_id: "p1", status: "published"}

    people = [
      %{doc_id: "p1", dataset: "d", user_id: "me", name: "Me Myself", color: "#111111"},
      %{doc_id: "p1", dataset: "d", user_id: "ada", name: "Ada Lovelace", color: "#222222"},
      %{doc_id: "p1", dataset: "d", user_id: "ada", name: "Ada Lovelace", color: "#222222"},
      %{doc_id: "p1", dataset: "x", user_id: "cy", name: "Cy", color: "#333333"}
    ]

    state = DocStatus.state(%{editor_doc: doc, dataset: "d", presences: people, user_id: "me"})
    assert Enum.map(state.presences, & &1.name) == ["Ada Lovelace"]

    html = render_component(&DocStatus.chips/1, Map.put(state, :doc, doc))
    assert html =~ ~s(data-testid="presence")

    assert html =~
             ~r/<span class="p-avatar" style="background: #222222" title="Ada Lovelace">\s*AL\s*<\/span>/

    refute html =~ "presence-dot"

    alone =
      DocStatus.state(%{
        editor_doc: doc,
        dataset: "d",
        presences: Enum.take(people, 1),
        user_id: "me"
      })

    refute render_component(&DocStatus.chips/1, Map.put(alone, :doc, doc)) =~ "p-avatar"
  end

  test "(e) past three people, a counter of the rest before the last two" do
    many =
      for {name, i} <-
            Enum.with_index(["Ann One", "Bo Two", "Cy Three", "Di Four", "ed.five@x.no"]),
          do: %{doc_id: "p1", dataset: "d", user_id: "u#{i}", name: name, color: "#000000"}

    html =
      render_component(&DocStatus.chips/1,
        doc: %{},
        draft?: false,
        published?: true,
        presences: many
      )

    avatars =
      Regex.scan(~r/class="p-avatar(?: more)?"[^>]*>\s*([^<]*?)\s*</, html)
      |> Enum.map(&List.last/1)

    assert avatars == ["3", "DF", "EF"]
  end

  # ── (f) ───────────────────────────────────────────────────────────────────

  test "(f) the header's icons in TanStack's order: Share, the menu, Split, Focus, close", c do
    view = open(c)

    labels =
      Regex.scan(
        ~r/<(?:button|a)\b[^>]*aria-label="([^"]+)"/,
        view |> element("#{@pane} > .pane-header") |> render()
      )
      |> Enum.map(&List.last/1)

    assert [
             "Share document",
             "Show document actions",
             "Split pane right",
             "Enter focus mode" <> _,
             "Close" <> _
           ] = Enum.reject(labels, &(&1 in ["Copy document ID", "Copy document URL"]))
  end

  test "(f) the icons after the menu sit beside it, not pushed apart" do
    css = rendered_to_string(BarkparkWeb.Studio.Desk.Style.sheet(%{}))
    assert css =~ ".dk .dk-doc-menu + .dk-split { margin-left: 0; }"
  end

  # ── (g) ───────────────────────────────────────────────────────────────────

  test "(g) the footer's Publish carries TanStack's upload arrow", c do
    view = open(c)
    publish = view |> element("#{@pane} [data-desk-publish]") |> render()
    assert publish =~ "M7.5 14L12.5 9.00006L17.5 14"
  end
end
