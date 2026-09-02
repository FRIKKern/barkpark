defmodule BarkparkWeb.Studio.NilIconNeverCrashesTest do
  @moduledoc """
  The desk destination stops RAISING (spd-w18-nil-icon-500).

  On the deployed build an authenticated admin got HTTP 500 from
  `/studio/rest` and `/studio/plugins` while `/studio` returned 200 —
  and clicking the `…Rest` desk row was simply DEAD (no URL change, no
  `aria-current`, silent console), because `Scope.select` only
  `push_patch`es and cannot tell a crashing destination from a no-op.
  Guerrilla's journal named the seam exactly:

      ** (FunctionClauseError) no function clause matching in
         BarkparkWeb.Icons.resolve_paths/2
        icons.ex:258: BarkparkWeb.Icons.resolve_paths(nil, :warn)
        icons.ex:293: BarkparkWeb.Icons."icon (overridable 1)"/1
        studio_live/components.ex:1106: anonymous fn/4 in …studio_live_shell/1

  ## Why nothing caught it

  Of the 20 files in `test/barkpark_web/studio/` only three mount a
  LiveView, and NONE of the five `pane_builder` suites RENDERS — they
  assert the pane DATA, so `icon: nil` passed every one of them. The
  icons tripwire is a literal scanner over `lib/`: it can see
  `name="foo"` and cannot see `name={item.icon}`. So this suite RENDERS.
  Every test here mounts a real destination and asserts HTML, because
  the only oracle that can fail is the render.

  ## The three crash sites, one per destination

    1. `/d/:ds/studio/plugins` — `Structure.plugin_group_node/2` set no
       `:icon` at all, so every `plugin-grp-*` child arrived nil.
       STRUCTURAL: no fixtures needed.
    2. `/d/:ds/studio/rest` — `Structure.rest_child_node/3` has two nil
       paths (the orphan branch omits `:icon`; the schema branch takes
       `Map.get(schema, :icon)`, nil for any schema that declared none).
    3. any document of an ICONLESS schema — `studio_editor_shell/1`
       rendered `@editor_schema.icon` unguarded, so the whole Studio
       editor 500s. The largest of the three: it is not a desk tier, it
       is every document of that type.

  Under `:test` `@unknown_icon_policy` is `:raise`, so all three
  reproduce offline with no browser — which is why this is a test and
  not a Playwright script.

  ## The policy fork

  `resolve_paths/2`'s non-binary clause is POLICY-AWARE, mirroring
  `unknown_icon/3`: `:warn` (dev/prod) falls back to the "file" glyph,
  `:raise` (test) raises `ArgumentError`. That is why the three render
  tests above must pass with the `:raise` arm LIVE — they pass because
  the EMITTERS and the CALL SITES were fixed, not because the renderer
  swallows nil. If a future unguarded dynamic `name={…}` site appears,
  it reds here instead of shipping a silent "file" glyph.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @admin_token "nil-icon-never-crashes-admin-token"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "nil icon guard admin", @dataset, [
        "read",
        "write",
        "admin"
      ])

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
  end

  describe "the Plugins tier destination" do
    test "/studio/plugins renders on a clean DB — the plugin-group nil icon was STRUCTURAL",
         %{conn: conn} do
      # No fixtures on purpose: `plugin_group_node/2` emitted `icon: nil`
      # unconditionally, so this crashed on an empty database.
      #
      # `assert html =~ "pane-layout"` ALONE would be a proof that cannot fail
      # for the reason it claims: the desk chrome renders whether or not a
      # single plugin-group row materialised, so an empty Plugins column would
      # pass it. The row assertions below are what make this render
      # load-bearing (spd-plugins-render-assert-weak) — the same discipline the
      # …Rest test applies with its `orphan_thing` assertion.
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/plugins"))

      assert html =~ "pane-layout"

      doc = LazyHTML.from_document(html)

      rows = LazyHTML.query(doc, ~s(button[id^="item-plugin-grp-"].pane-item))

      assert Enum.count(rows) > 0,
             "the Plugins column rendered no plugin-group row at all — this render proves nothing"

      # A NAMED row, not just "some row": `onixedit` is an installed plugin in
      # every env (`:barkpark, :plugins`), and the desk resolves its column
      # under `gating: :none`, so its group row is present on a clean DB.
      row = LazyHTML.query(doc, ~s(button#item-plugin-grp-onixedit.pane-item))

      assert Enum.count(row) == 1,
             "the Plugins column must carry the onixedit group row; it rendered " <>
               inspect(plugin_group_ids(rows))

      label =
        row |> LazyHTML.query("span.pane-item-label") |> LazyHTML.text() |> String.trim()

      assert label == "Onix",
             "the onixedit group row must wear its display name, got #{inspect(label)}"

      # THE ICON, DRAWN. The call site is `<.icon name={Icons.drawable_name(item.icon)} />`,
      # which collapses a nil to the neutral "file" glyph — so a nil icon can
      # never RAISE here, and a render test that only checks presence stays
      # green while every plugin row silently degrades to a document glyph.
      # Assert the picture: the row must carry the "puzzle" paths the emitter
      # names, not the fallback. This is the assertion that reds when
      # `plugin_group_node/2` drops `icon:` AND `PaneBuilder`s `|| "file"` goes.
      drawn = path_shapes(row, "span.pane-item-icon svg")

      assert drawn == glyph_shapes("puzzle"),
             "the onixedit group row drew a different glyph than the emitters " <>
               "\"puzzle\" — a plugin row that fell back to " <>
               "#{inspect(fallback_glyph_name(drawn))} is the nil-icon defect wearing " <>
               "a fail-safe costume"

      refute drawn == glyph_shapes("file"),
             "the onixedit group row drew the neutral \"file\" fallback — the emitter " <>
               "stopped naming a glyph, or the PaneBuilder forwarding lost it"
    end
  end

  describe "the …Rest tier destination" do
    setup do
      # Two rest children, one per nil path of `rest_child_node/3`:
      #   * `nil_icon_widget` — a schema that declares NO icon (schema branch)
      #   * `orphan_thing`    — a type with no schema at all (orphan branch)
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "nil_icon_widget", "title" => "Nil Icon Widget", "fields" => []},
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "nil_icon_widget",
          %{"doc_id" => "nil-icon-widget-1", "title" => "Widget One", "content" => %{}},
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "orphan_thing",
          %{"doc_id" => "orphan-thing-1", "title" => "Orphan One", "content" => %{}},
          @dataset
        )

      :ok
    end

    test "the schema branch's nil icon does not crash the desk: /studio/rest renders",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/rest"))

      assert html =~ "pane-layout"
    end

    test "the …Rest rows are actually PRESENT — the render is not passing by being empty",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/rest"))

      assert html =~ "orphan_thing",
             "the orphan-branch rest child must render, or this suite proves nothing"
    end
  end

  describe "the Studio editor destination (the third, largest crash site)" do
    test "a document whose schema declares NO icon opens in the editor instead of 500ing",
         %{conn: conn} do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "iconless_note",
            "title" => "Iconless Note",
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "iconless_note",
          %{"doc_id" => "iconless-note-1", "title" => "No Icon Here", "content" => %{}},
          @dataset
        )

      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/iconless_note/iconless-note-1"))

      assert html =~ "No Icon Here"
    end
  end

  describe "Icons.resolve_paths/2 fail-safe (the class, not the three instances)" do
    test "a nil name falls back under :warn — the arm production runs" do
      file = BarkparkWeb.Icons.resolve_paths("file", :warn)

      assert BarkparkWeb.Icons.resolve_paths(nil, :warn) == file
    end

    test "a nil name RAISES under :raise — an unguarded dynamic site is a bug in test" do
      assert_raise ArgumentError, ~r/non-binary icon name nil/, fn ->
        BarkparkWeb.Icons.resolve_paths(nil, :raise)
      end
    end

    test "both arms hold for every other non-binary shape a nil-ish assign can take" do
      file = BarkparkWeb.Icons.resolve_paths("file", :warn)

      for name <- [nil, :atom_icon, 42, %{}, [], {:tuple}] do
        assert BarkparkWeb.Icons.resolve_paths(name, :warn) == file,
               "resolve_paths/2 must fall back for #{inspect(name)} under :warn — prod never 500s"

        assert_raise ArgumentError, fn ->
          BarkparkWeb.Icons.resolve_paths(name, :raise)
        end
      end
    end

    test "an unknown BINARY name still RAISES under :raise — the tripwire keeps its teeth" do
      assert_raise ArgumentError, fn ->
        BarkparkWeb.Icons.resolve_paths("definitely-not-a-glyph", :raise)
      end
    end

    test "drawable_name/2 collapses both failure shapes at the call site" do
      assert BarkparkWeb.Icons.drawable_name("folder") == "folder"
      assert BarkparkWeb.Icons.drawable_name(nil) == "file"
      assert BarkparkWeb.Icons.drawable_name(nil, "circle") == "circle"
      assert BarkparkWeb.Icons.drawable_name("definitely-not-a-glyph", "circle") == "circle"
      # emoji aliases resolve, so a schema carrying "🗂" keeps its picture
      assert BarkparkWeb.Icons.drawable_name("🗂") == "🗂"
    end
  end

  describe "the emitters no longer produce nil" do
    test "plugin_group_node emits a real, drawable icon — on a clean DB" do
      # `gating: :none` is RESOLUTION mode, the tree PaneBuilder falls back to
      # when a nav segment is absent from the gated display — which is exactly
      # how `/studio/plugins` materialises its column (and crashed) even on a
      # database with zero fixtures.
      plugins =
        @dataset
        |> Barkpark.Structure.build(gating: :none)
        |> find_node("plugins")

      assert plugins, "the Plugins tier must resolve under gating: :none, or this proves nothing"
      assert plugins.items != []

      for child <- plugins.items do
        assert BarkparkWeb.Icons.known_icon?(child.icon),
               "plugin group #{child.id} emitted a non-drawable icon: #{inspect(child.icon)}"
      end
    end

    test "rest_child_node emits a drawable icon on BOTH paths (schema and orphan)" do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "nil_icon_widget", "title" => "Nil Icon Widget", "fields" => []},
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "nil_icon_widget",
          %{"doc_id" => "nil-icon-widget-2", "title" => "Widget Two", "content" => %{}},
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "orphan_thing",
          %{"doc_id" => "orphan-thing-2", "title" => "Orphan Two", "content" => %{}},
          @dataset
        )

      rest = @dataset |> Barkpark.Structure.build(gating: :enabled) |> find_node("rest")

      assert rest, "…Rest tier must exist for this proof — the fixtures above seed it"
      assert rest.items != []

      for child <- rest.items do
        assert BarkparkWeb.Icons.known_icon?(child.icon),
               "…Rest child #{child.id} emitted a non-drawable icon: #{inspect(child.icon)}"
      end
    end
  end

  # ── Render helpers (element/attribute assertions, never substring greps) ──

  # The `d` attributes an svg actually painted, in order.
  defp path_shapes(fragment, selector) do
    fragment |> LazyHTML.query(selector <> " path") |> LazyHTML.attribute("d")
  end

  # The same shapes for a NAMED glyph, read from the icon library rather than
  # pasted here, so a glyph redraw updates both sides at once.
  defp glyph_shapes(name) do
    name
    |> BarkparkWeb.Icons.resolve_paths(:warn)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("path")
    |> LazyHTML.attribute("d")
  end

  # Name the glyph a row actually drew, for the failure message.
  defp fallback_glyph_name(shapes) do
    Enum.find(BarkparkWeb.Icons.icon_names(), "an unknown glyph", &(glyph_shapes(&1) == shapes))
  end

  defp plugin_group_ids(rows), do: LazyHTML.attribute(rows, "id")

  # Walk the desk tree for a node id (the tree is nested; …Rest and Plugins
  # both sit at the top level today, but the walk keeps this honest if a
  # later tier nests them).
  defp find_node(%Barkpark.Structure.Node{} = root, id), do: find_node([root], id)

  defp find_node(nodes, id) when is_list(nodes) do
    Enum.find_value(nodes, fn
      %{id: ^id} = node -> node
      %{items: items} when is_list(items) -> find_node(items, id)
      _ -> nil
    end)
  end

  defp find_node(_, _), do: nil
end
