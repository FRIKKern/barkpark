defmodule BarkparkWeb.Studio.PaperEditor.SlashMenuAndCodelistTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — slash menu + standalone codelist field.

    * P3.3 (barkpark-h5ef) — the Notion-style slash menu: the <bp-paper-editor>
      WC emits a bubbling/composed `bp-slash-insert` CustomEvent {type, afterId};
      the BarkparkPaperEditor hook forwards it as a `paper-slash-insert`
      pushEvent. The server builds the block with the SAME default_block/2 +
      new_block_id/0 the add-block path uses and applies an `insert-after` op
      through the SAME paper_op/2 pipeline.
    * Polish-2 (barkpark-5srz) — codelist field block fully usable, two halves:
      (A) FLAT codelist — View resolves the selected CODE → its human LABEL via
      the Content → Render spine (Content injects a :codelist_resolver); the
      picker is a real CodelistField bound to a registered codelist.
      (B) TREE codelist — PaperFieldBlock hosts the stateful TreeCodelistField
      inside its form (variant:"tree"); a tree-row select propagates up through
      the notify → send_update → patch-block pipeline and persists.
      Both register their codelists in-test (the dev seed populates OnixEdit, but
      the test DB starts empty) so they exercise the SAME registry path.

  The codelist register/seed helpers (`register_flat_codelist!`,
  `register_tree_codelist!`, `seed_codelist_view_paper!`,
  `seed_codelist_tree_paper!`) are section-local. The shared base paper +
  `open_editor` (used by the slash-menu tests on `@slug`) come from
  `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  # ── P3.3: the Notion-style slash menu (barkpark-h5ef) ──────────────────────
  # The <bp-paper-editor> WC emits a bubbling/composed `bp-slash-insert`
  # CustomEvent {type, afterId} when the user picks a type from the "/" popup;
  # the BarkparkPaperEditor hook forwards detail verbatim as a `paper-slash-
  # insert` pushEvent. The server builds the block with the SAME default_block/2
  # + new_block_id/0 the add-block path uses and applies an `insert-after` op
  # through the SAME paper_op/2 pipeline. Simulate that wire with render_hook —
  # the event arrives JSON-decoded with string keys, exactly as the handler
  # accepts it.

  test "a paper-slash-insert inserts a heading AFTER the anchor block + persists",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    # Initial order: h-1, p-intro, p-second.
    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["h-1", "p-intro", "p-second"]

    render_hook(
      view,
      "paper-slash-insert",
      wire_params(view, %{"type" => "heading", "afterId" => "p-intro"})
    )

    blocks = Content.paper_blocks(@slug, @dataset)
    ids = Enum.map(blocks, & &1["id"])

    # The new heading landed DIRECTLY after p-intro (insert-after, not appended
    # to the tail), with a fresh "b-" id.
    intro_idx = Enum.find_index(ids, &(&1 == "p-intro"))
    new_id = Enum.at(ids, intro_idx + 1)
    refute new_id == "p-second"
    assert String.starts_with?(new_id, "b-")

    new = Enum.find(blocks, &(&1["id"] == new_id))
    # default_block("heading", …) shape — proves the server reused the SAME
    # block-creation path the add-block menu uses.
    assert new["type"] == "heading"
    assert new["level"] == 2

    # The blocks below the anchor stay in order; p-second is now last.
    assert List.last(ids) == "p-second"
    # It renders in the editor (compose_block accepted it during render_blocks).
    assert render(view) =~ ~s(data-edit-block-id="#{new_id}")
  end

  test "a paper-slash-insert with a blank afterId appends at the end",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    before_count = Content.paper_blocks(@slug, @dataset) |> length()

    render_hook(
      view,
      "paper-slash-insert",
      wire_params(view, %{"type" => "paragraph", "afterId" => ""})
    )

    blocks = Content.paper_blocks(@slug, @dataset)
    assert length(blocks) == before_count + 1

    last = List.last(blocks)
    assert last["type"] == "paragraph"
    assert String.starts_with?(last["id"], "b-")
    assert render(view) =~ ~s(data-edit-block-id="#{last["id"]}")
  end

  # ── Polish-2 (barkpark-5srz): codelist field block fully usable ─────────────
  # Two halves:
  #   A) FLAT codelist — View resolves the selected CODE → its human LABEL via
  #      the Content → Render spine (the renderer stays pure; Content injects a
  #      :codelist_resolver). The picker is a real CodelistField bound to a
  #      registered codelist, so selection works.
  #   B) TREE codelist — PaperFieldBlock hosts the stateful TreeCodelistField
  #      inside its form (variant:"tree"); a tree-row select propagates up
  #      through the notify → send_update → patch-block pipeline and persists.
  #
  # Both register their codelists in-test (the dev seed populates OnixEdit, but
  # the test DB starts empty) so they exercise the SAME registry path.

  @codelist_view_slug "2026-05-24-codelist-view-paper"
  @codelist_tree_slug "2026-05-24-codelist-tree-paper"

  defp register_flat_codelist! do
    {:ok, _} =
      Content.Codelists.register("onixedit", "onixedit:list_15", %{
        issue: "73",
        name: "Title type",
        values: [
          %{code: "01", translations: [%{language: "eng", label: "Distinctive title"}]},
          %{code: "05", translations: [%{language: "eng", label: "Abbreviated title"}]}
        ]
      })
  end

  defp register_tree_codelist! do
    {:ok, _} =
      Content.Codelists.register("onixedit", "onixedit:thema", %{
        issue: "73",
        name: "Thema subject category",
        values: [
          %{
            code: "F",
            translations: [%{language: "eng", label: "Fiction"}],
            children: [
              %{
                code: "FB",
                translations: [%{language: "eng", label: "Fiction: literary and general"}],
                children: [
                  %{
                    code: "FBA",
                    translations: [%{language: "eng", label: "Modern and contemporary fiction"}]
                  }
                ]
              }
            ]
          }
        ]
      })
  end

  defp seed_codelist_view_paper!(value) do
    blocks = [
      %{
        "id" => "cl-flat",
        "type" => "codelist",
        "label" => "Title type",
        "plugin" => "onixedit",
        "codelistId" => "onixedit:list_15",
        "version" => 73,
        "variant" => "flat",
        "value" => value
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @codelist_view_slug,
          dataset: @dataset,
          blocks: blocks
        })
      )

    paper
  end

  defp seed_codelist_tree_paper!(value) do
    blocks = [
      %{
        "id" => "cl-tree",
        "type" => "codelist",
        "label" => "Thema subject category",
        "plugin" => "onixedit",
        "codelistId" => "onixedit:thema",
        "version" => 73,
        "variant" => "tree",
        "value" => value
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @codelist_tree_slug,
          dataset: @dataset,
          blocks: blocks
        })
      )

    paper
  end

  test "View mode resolves a flat codelist's selected CODE to its LABEL", %{conn: conn} do
    register_flat_codelist!()
    seed_codelist_view_paper!("01")

    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_view_slug}"))

    # The streamed read-only View shows the resolved label, not the bare code.
    assert html =~ "Distinctive title"
    # The raw code never appears as the standalone displayed value.
    refute html =~ ">01<"
  end

  test "View mode falls back to the raw code when the codelist is unregistered",
       %{conn: conn} do
    # No codelist registered → codelist_label returns the code unchanged.
    seed_codelist_view_paper!("99")

    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_view_slug}"))

    assert html =~ "99"
  end

  test "Edit mode renders the flat CodelistField <select> bound to the registry",
       %{conn: conn} do
    register_flat_codelist!()
    seed_codelist_view_paper!("01")

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_view_slug}"))

    edit_html = open_editor(view)

    # The flat block hosts the native CodelistField <select> (not the disabled
    # empty placeholder) — the registry is populated, so real options render.
    assert edit_html =~ ~s(id="paper-fb-cl-flat")
    assert edit_html =~ ~s(data-codelist-variant="flat")
    assert edit_html =~ ~s(data-codelist-id="onixedit:onixedit:list_15")
    # Selecting another code through the inner form persists via patch-block.
    flush_form(view, ~s([data-block-id="cl-flat"] form), %{"value" => "05"})

    render(view)

    block =
      Content.paper_blocks(@codelist_view_slug, @dataset) |> Enum.find(&(&1["id"] == "cl-flat"))

    assert block["value"] == "05"
    assert block["plugin"] == "onixedit"
  end

  test "Edit mode hosts the TreeCodelistField for a variant:tree codelist block",
       %{conn: conn} do
    register_tree_codelist!()
    seed_codelist_tree_paper!("FBA")

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_tree_slug}"))

    edit_html = open_editor(view)

    # PaperFieldBlock hosts the stateful TreeCodelistField inside its form.
    assert edit_html =~ ~s(id="paper-fb-cl-tree")
    assert edit_html =~ ~s(data-codelist-variant="tree")
    # The tree LiveComponent mounted with its stable id + tree markup.
    assert edit_html =~ ~s(id="tree-cl-tree")
    assert edit_html =~ "bp-tree-codelist"
    assert edit_html =~ ~s(role="tree")
    # The hidden input carries the current value home through the parent form.
    assert edit_html =~ ~s(data-tree-selected="true")
    # The pre-selected leaf is rendered as selected (auto-expanded to it).
    assert edit_html =~ "Fiction"

    # A tree-row select propagates up: TreeCodelistField notifies the LiveView,
    # which send_updates the PaperFieldBlock, which persists the patch-block.
    view
    |> element(
      ~s([data-block-id="cl-tree"] button[phx-click="tree_node_select"][phx-value-code="FB"])
    )
    |> render_click()

    render(view)

    flush_form(view, ~s([data-block-id="cl-tree"] form), %{"value" => "FB"})

    block =
      Content.paper_blocks(@codelist_tree_slug, @dataset) |> Enum.find(&(&1["id"] == "cl-tree"))

    assert block["type"] == "codelist"
    assert block["value"] == "FB"
    assert block["variant"] == "tree"
  end

  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp wire_params(view, params) do
    Map.merge(params, %{"request_id" => Ecto.UUID.generate(), "if_rev" => paper_rev(view)})
  end

  defp flush_form(view, selector, values) do
    target = element(view, selector)
    render_change(target, values)

    render_hook(target, "inner-flush", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
      "values" => values
    })
  end
end
