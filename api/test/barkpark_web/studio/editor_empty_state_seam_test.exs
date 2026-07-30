defmodule BarkparkWeb.Studio.EditorEmptyStateSeamTest do
  @moduledoc """
  spd-w19 — THE THIRD SEAM. A document that does not resolve must name its id,
  its type and its reason. Never `"Select a document to edit"`.

  The disease this pins, generalised past papers: the editor shell's
  `<:empty_state>` slot has been DECLARED since D222 and never filled, so every
  one of PaneBuilder's nine nil-editor producers rendered the SAME shrug —
  a deleted document, a schemaless type, a stale desk link and "nothing
  selected" were all one sentence. The reasons are indistinguishable at the
  shell's attrs (every producer returns a bare `nil`), so the derivation lives in
  `Shared.empty_editor_state/2` over `(panes, nav_path)` and is proven here by
  DRIVING the public `PaneBuilder.walk_path/7` — never by hand-writing a pane
  stack the walk would not produce.

  FIXTURE PROHIBITION (charter D260/D237): no case here fixtures `blocks: []`.
  A `blocks: []` document RESOLVES — `build_editor` returns `view: :paper` with a
  non-nil doc — so it never reaches `studio_editor_shell`'s empty branch at all
  and a guard fixtured that way is a FALSE GREEN. Every case below fixtures
  NON-RESOLUTION: a missing id, an unmatched first segment, or a real type whose
  schema is not installed.
  """

  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.StudioComponents.Editor

  defp insert_schema!(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert!()
  end

  # Mirror `PaneBuilder.build/3`'s entry exactly: the root `:nav` pane is seeded
  # BEFORE the walk (pane_builder.ex `build/3`), and `empty_editor_state/2` reads
  # the whole stack. Driving `walk_path/7` with `panes: []` would hide the
  # `:unknown_node` shape entirely.
  defp walk(path, root, dataset) do
    root_pane = %{
      title: root.title,
      role: :nav,
      priority: 0,
      items: [],
      selected: Enum.at(path, 0)
    }

    PaneBuilder.walk_path(path, 0, root, [root_pane], nil, dataset, [])
  end

  defp state(path, root, dataset) do
    {panes, editor} = walk(path, root, dataset)

    assert editor == nil,
           "fixture must NOT resolve — a resolving fixture never reaches the empty branch"

    {panes, Shared.empty_editor_state(panes, path)}
  end

  defp render_notice(state, opts \\ []) do
    render_component(&Editor.unresolved_document_notice/1, %{
      reason: state.reason,
      doc_id: state.doc_id,
      doc_type: state.doc_type,
      list_href: Keyword.get(opts, :list_href),
      desk_href: "/d/production/studio"
    })
  end

  describe "the four reasons are DERIVED, each from a fixture that genuinely does not resolve" do
    test ":not_found — the type is real and installed, the id is not in this dataset" do
      dataset = "spdw19_not_found"

      insert_schema!(%{
        name: "post",
        title: "Posts",
        icon: "file-text",
        visibility: "public",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}]
      })

      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items: [%Node{id: "posts", title: "Posts", type: :document_type_list, type_name: "post"}]
      }

      {panes, st} = state(["post", "ghost-id"], root, dataset)

      assert length(panes) == 2
      assert List.last(panes).role == :list
      assert List.last(panes).type_name == "post"

      assert st == %{reason: :not_found, doc_id: "ghost-id", doc_type: "post"}

      html = render_notice(st, list_href: "/d/#{dataset}/studio/post")
      assert html =~ ~s(data-reason="not_found")
      assert html =~ "ghost-id"
      assert html =~ "No post with the id"
    end

    test ":no_schema — a FABRICATED schemaless orphan under the …Rest column" do
      dataset = "spdw19_no_schema"

      # No schema row for "orphanType" anywhere. The real door: Structure
      # degrades a schemaless-but-referenced type to a non-drillable `:document`
      # node under …Rest, and PaneBuilder's `:document` branch returns
      # `{panes, nil}` when `Content.get_schema/2` finds nothing
      # (pane_builder.ex `%{type: :document}`). The "open" backlinks door
      # RESOLVES the same document with `schema: nil`, so `:no_schema` is
      # desk-path-only by construction.
      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items: [
          %Node{
            id: "rest",
            title: "…Rest",
            type: :list,
            items: [
              %Node{id: "orphan", title: "Orphan", type: :document, type_name: "orphanType"}
            ]
          }
        ]
      }

      {panes, st} = state(["rest", "orphanType"], root, dataset)

      assert length(panes) == 2
      last = List.last(panes)
      assert last.role == :list
      refute Map.get(last, :type_name), "the …Rest pane carries NO type_name — that IS the signal"

      assert st == %{reason: :no_schema, doc_id: "orphanType", doc_type: "orphanType"}

      html = render_notice(st)
      assert html =~ ~s(data-reason="no_schema")
      assert html =~ "No schema for"
      assert html =~ "orphanType"
    end

    test ":unknown_node — the first segment names no node in this desk" do
      dataset = "spdw19_unknown"

      root = %Node{id: "root", title: "Content", type: :list, items: []}

      {panes, st} = state(["retiredPlugin", "some-id"], root, dataset)

      assert length(panes) == 1, "the walk never advanced past the root pane"
      assert List.last(panes).role == :nav

      assert st == %{reason: :unknown_node, doc_id: "some-id", doc_type: "retiredPlugin"}

      html = render_notice(st)
      assert html =~ ~s(data-reason="unknown_node")
      assert html =~ "has no section named"
      assert html =~ "retiredPlugin"
      assert html =~ "some-id"
    end

    test ":nothing_selected — nav_path is empty, and this state does NOT shout" do
      dataset = "spdw19_nothing"

      root = %Node{id: "root", title: "Content", type: :list, items: []}
      {_panes, st} = state([], root, dataset)

      assert st == %{reason: :nothing_selected, doc_id: nil, doc_type: nil}

      html = render_notice(st)
      assert html =~ ~s(data-test-id="studio-editor-nothing-selected")
      refute html =~ ~s(role="alert"), "nothing went wrong, so nothing shouts"

      refute html =~ "Select a document to edit",
             "the shrug is gone even from the calm state"
    end

    test ":nothing_selected — drilled to a list, picked nothing: NOT an accusation" do
      dataset = "spdw19_list_no_pick"

      insert_schema!(%{
        name: "post",
        title: "Posts",
        icon: "file-text",
        visibility: "public",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}]
      })

      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items: [%Node{id: "posts", title: "Posts", type: :document_type_list, type_name: "post"}]
      }

      # nav_path names the TYPE, not a document. Reading `:not_found` off this
      # shape would invent "no post with the id post" — a shrug in a louder
      # costume, and it would have broken wave 18's own journey precondition.
      {panes, st} = state(["post"], root, dataset)

      assert List.last(panes).type_name == "post"
      assert List.last(panes).selected == nil

      assert st == %{reason: :nothing_selected, doc_id: nil, doc_type: nil}
    end

    test "the four reasons render four DISTINCT bodies" do
      bodies =
        for reason <- [:not_found, :no_schema, :unknown_node, :nothing_selected] do
          render_notice(%{reason: reason, doc_id: "d1", doc_type: "post"})
        end

      assert length(Enum.uniq(bodies)) == 4,
             "a reason that renders identically to another reason is the shrug again"
    end
  end

  describe "the rendered state is honest: id, real type, reason, and a named way out" do
    test "role=alert + aria-live + stable data-test-id + id + type + focusable recovery" do
      html =
        render_notice(%{reason: :not_found, doc_id: "ghost-id", doc_type: "session"},
          list_href: "/d/production/studio/session"
        )

      assert html =~ ~s(role="alert")
      assert html =~ ~s(aria-live="assertive")
      assert html =~ ~s(data-test-id="studio-unresolved-document-notice")
      assert html =~ ~s(data-doc-id="ghost-id")
      assert html =~ ~s(data-doc-type="session")
      assert html =~ "ghost-id"
      assert html =~ "session"

      # Named recovery controls, both natively tabbable. The DECIDED focus
      # destination for spd-bl-focus-after-select (charter D269) is the
      # tabindex="-1" LANDMARK — this notice's own role="alert" container, so a
      # `.focus()` announces the whole reason — and NOT the recovery control:
      # `tabindex="-1"` on an `<a href>` buys nothing (an anchor is already
      # programmatically focusable) while removing it from the tab order.
      assert html =~ ~s(data-test-id="studio-unresolved-recovery")
      assert html =~ ~s(href="/d/production/studio/session")
      assert html =~ "Back to the session list"
      assert html =~ ~s(data-test-id="studio-unresolved-back-to-desk")
    end

    test "EVERY alert arm offers a way out that a KEYBOARD can reach" do
      for {reason, opts} <- [
            {:not_found, [list_href: "/d/production/studio/post"]},
            {:no_schema, []},
            {:unknown_node, []}
          ] do
        html = render_notice(%{reason: reason, doc_id: "x", doc_type: "post"}, opts)

        assert html =~ ~s(data-test-id="studio-unresolved-recovery"),
               "#{reason} must offer a named way out"

        # The binary that matters: the way out is in the TAB ORDER. `:no_schema`
        # and `:unknown_node` render ONE control apiece, so a `tabindex="-1"` on
        # it (which is how this shipped) left them mouse-only — a dead control to
        # a keyboard user, which is the owner's original complaint in a new place.
        recovery =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(~s([data-test-id="studio-unresolved-recovery"]))

        assert Enum.count(recovery) == 1
        assert LazyHTML.attribute(recovery, "href") != [], "#{reason}'s way out has no href"

        assert LazyHTML.attribute(recovery, "tabindex") == [],
               "#{reason}'s only way out carries a tabindex — an <a href> is already focusable, and -1 removes it from the tab order"
      end
    end

    test "the DECIDED focus destination (D269) is the alert LANDMARK, not the control" do
      html = render_notice(%{reason: :unknown_node, doc_id: "x", doc_type: "gone"})

      landmark =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test-id="studio-unresolved-document-notice"]))

      assert LazyHTML.attribute(landmark, "tabindex") == ["-1"],
             "a later slice must be able to .focus() the whole reason, not just a button label"

      assert LazyHTML.attribute(landmark, "role") == ["alert"]
    end

    test "the shrug string is unreachable from every arm of the notice" do
      for reason <- [:not_found, :no_schema, :unknown_node, :nothing_selected] do
        html = render_notice(%{reason: reason, doc_id: "d1", doc_type: "post"})

        refute html =~ "Select a document to edit",
               "#{reason} must not fall back to the default empty_editor copy"
      end
    end
  end

  describe "the seam's boundaries (what this slice deliberately does NOT own)" do
    test "unrenderable_content is NOT a reason here — #7897 owns that arm" do
      source = File.read!("lib/barkpark_web/live/studio/studio_live/shared.ex")

      refute source =~ ":unrenderable_content",
             "a document that RESOLVES and cannot render is unrenderable_document_notice/1's arm"

      # The atom, not the prose: editor.ex's own comment NAMES the sibling arm to
      # keep the boundary legible, which is documentation, not an emitted reason.
      refute File.read!("lib/barkpark_web/components/studio_components/editor.ex") =~
               ":unrenderable_content"

      refute File.read!("lib/barkpark_web/live/studio/studio_live/components.ex") =~
               ":unrenderable_content"
    end

    test "draft_only is absent — D220's draft-first fetch makes it unfirable" do
      for file <- [
            "lib/barkpark_web/live/studio/studio_live/shared.ex",
            "lib/barkpark_web/components/studio_components/editor.ex",
            "lib/barkpark_web/live/studio/studio_live/components.ex"
          ] do
        refute File.read!(file) =~ ":draft_only",
               "#{file}: a never-published document RESOLVES draft-first, so the reason cannot fire"
      end
    end

    test "PaneBuilder.build/3 still returns a 2-tuple — no 36-call-site widening" do
      dataset = "spdw19_tuple"
      assert {panes, nil} = PaneBuilder.build(dataset, ["nope", "x"])
      assert is_list(panes)
    end

    test "the slot is filled at the SOLE studio_editor_shell call site" do
      source = File.read!("lib/barkpark_web/live/studio/studio_live/components.ex")

      assert source =~ "<:empty_state>", "the declared-and-never-filled slot is now filled"

      assert source =~ "unresolved_document_notice",
             "the fill renders the derived notice, not a new inline shrug"

      # The fill must sit INSIDE the shell call, after its opening tag and before
      # its close — a fill anywhere else is not on this render path.
      [_, after_open] = String.split(source, "<.studio_editor_shell", parts: 2)
      [inside, _] = String.split(after_open, "</.studio_editor_shell>", parts: 2)
      assert inside =~ "<:empty_state>"
    end

    test "D222's prohibitions hold: no editor-body class, no editor_doc resurrection" do
      editor = File.read!("lib/barkpark_web/components/studio_components/editor.ex")

      notice =
        editor
        |> String.split("def unresolved_document_notice")
        |> Enum.at(1)
        |> String.split("@doc \"\"\"")
        |> List.first()

      refute notice =~ "editor-body", "D180: the notice never claims the editor-body class"
      refute notice =~ "editor_doc", "D222: never resurrect editor_doc here"
    end
  end

  describe "the honest bound" do
    test "the derivation is type-AGNOSTIC: it names whatever type the pane carried" do
      # This is the whole generalisation. The reason machinery never mentions
      # "paper" — it reports the pane's own type_name, including a type that
      # exists in NO code registry (guerrilla's user-created `metric`, prod's
      # `place`). The guard is a floor, not a completeness claim.
      for type <- ["paper", "sheet", "task", "session", "metric", "place"] do
        panes = [
          %{role: :nav, priority: 0, items: [], selected: type},
          %{role: :list, priority: :active, type_name: type, items: [], selected: "ghost"}
        ]

        st = Shared.empty_editor_state(panes, [type, "ghost"])
        assert st == %{reason: :not_found, doc_id: "ghost", doc_type: type}
        assert render_notice(st) =~ type
      end
    end
  end

  # Sanity anchor for the fixture prohibition above: proving the false green is
  # real is what keeps the prohibition from decaying into folklore.
  test "PROOF the prohibited fixture is a false green: blocks: [] RESOLVES" do
    dataset = "spdw19_false_green"

    insert_schema!(%{
      name: "paper",
      title: "Papers",
      icon: "file-text",
      visibility: "public",
      dataset: dataset,
      fields: [%{"name" => "title", "type" => "string"}]
    })

    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => "blank-1", "title" => "Blank", "blocks" => []},
        dataset
      )

    root = %Node{
      id: "root",
      title: "Content",
      type: :list,
      items: [%Node{id: "papers", title: "Papers", type: :document_type_list, type_name: "paper"}]
    }

    {_panes, editor} = walk(["paper", "blank-1"], root, dataset)

    assert editor != nil, "a blocks: [] document RESOLVES"
    assert editor.view == :paper

    refute is_nil(editor.doc),
           "it never reaches the empty branch — fixturing it here would be a FALSE GREEN"
  end
end
