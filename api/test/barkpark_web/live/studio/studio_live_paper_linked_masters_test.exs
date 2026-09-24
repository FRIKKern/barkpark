defmodule BarkparkWeb.Studio.StudioLivePaperLinkedMastersTest do
  @moduledoc """
  LINKED paper-master instances (task-59f078a2fd248698), driven through the
  mounted Studio paper editor:

    * INSERT — `paper-insert-master` with `mode: "linked"` inserts ONE
      `master-ref` block (no copy) through the request-identified op path;
    * RENDER — the boundary preview shows the master's content, resolved per
      read; a master edit shows on the next open while the paper document is
      never written;
    * PIN / DETACH — the toolbar buttons freeze the instance to the master's
      current revision, and replace it with a detached copy;
    * TENANCY / PLUGIN OFF — a foreign master previews as "Master unavailable";
      with Bulldocs disabled the buttons are absent and the events refuse.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Masters

  @dataset "production"

  @section %{
    "id" => "lm-sec",
    "type" => "section",
    "title" => "Pricing block",
    "blocks" => [
      %{"id" => "lm-sec-h", "type" => "heading", "level" => 2, "text" => "Pricing"},
      %{"id" => "lm-sec-p", "type" => "paragraph", "text" => "Original master copy"}
    ]
  }

  setup do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    slug = "paper-linked-ui-#{System.unique_integer([:positive])}"

    blocks = [
      %{"id" => "lm-h", "type" => "heading", "level" => 1, "text" => "Linked paper"},
      %{"id" => "lm-p", "type" => "paragraph", "text" => "Intro."},
      @section
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    {:ok, master} =
      Masters.save_master(slug, "lm-sec", @dataset,
        workspace_id: paper.workspace_id,
        project_id: paper.project_id
      )

    %{slug: slug, paper: paper, master: master}
  end

  defp open(conn, slug) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp blocks(slug), do: Content.paper_blocks(slug, @dataset)

  defp paper_row(slug, paper),
    do:
      Content.get_paper(slug, @dataset,
        workspace_id: paper.workspace_id,
        project_id: paper.project_id
      )

  defp edit_master!(master, text) do
    node = put_in(@section, ["blocks", Access.at(1), "text"], text)

    {:ok, _} =
      Content.upsert_document(
        Masters.type_name(),
        %{
          "doc_id" => master.doc_id,
          "title" => master.title,
          "content" => Map.put(master.content, "node", node)
        },
        @dataset,
        workspace_id: master.workspace_id,
        project_id: master.project_id
      )

    # The save published the master, so an edit lands as its DRAFT: the row
    # Studio's authoring view (and Pin) reads.
    Content.get_document("drafts." <> Masters.master_id(master), Masters.type_name(), @dataset,
      workspace_id: master.workspace_id,
      project_id: master.project_id
    )
    |> elem(1)
  end

  defp preview(view, id),
    do:
      view
      |> element(~s([data-edit-block-id="#{id}"] [data-test-id="paper-master-ref-preview"]))
      |> render()

  defp insert_linked!(view, master) do
    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-insert-master", %{
      "master_id" => Masters.master_id(master),
      "after_id" => "lm-p",
      "request_id" => request_id,
      "if_rev" => assigns(view).paper_rev,
      "mode" => "linked"
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^request_id})
    request_id
  end

  test "insert linked, render the master, follow its edits without writing the paper, Pin, Detach",
       %{conn: conn, slug: slug, paper: paper, master: master} do
    view = open(conn, slug)
    insert_linked!(view, master)

    assert ["lm-h", "lm-p", ref_id, "lm-sec"] = Enum.map(blocks(slug), & &1["id"])
    ref = Enum.at(blocks(slug), 2)

    assert ref == %{
             "id" => ref_id,
             "type" => "master-ref",
             "master" => Masters.master_id(master),
             "version" => nil
           }

    # The boundary preview shows the master's content — nothing was copied.
    assert preview(view, ref_id) =~ "Original master copy"

    # ── the master changes; the instance paper is not written ───────────────
    before = paper_row(slug, paper)
    published_rev = master.rev
    draft = edit_master!(master, "Edited master copy")

    view = open(conn, slug)
    html = preview(view, ref_id)
    assert html =~ "Edited master copy"
    refute html =~ "Original master copy"

    after_edit = paper_row(slug, paper)
    assert after_edit.rev == before.rev
    assert after_edit.content["blocks"] == before.content["blocks"]

    # ── PIN: freeze to the master's latest PUBLISHED revision ───────────────
    # (task-881d4b6e857b1b65, 0010 §5b) — NOT the unpublished draft the
    # unpinned preview follows: a draft rev is never published, so the public
    # reader could never show it. After the pin, edit mode shows what the
    # public reader shows.
    assert view
           |> element(~s([data-edit-block-id="#{ref_id}"] [data-test-id="paper-pin-master"]))
           |> render() =~ "published version"

    view
    |> element(~s([data-edit-block-id="#{ref_id}"] [data-test-id="paper-pin-master"]))
    |> render_click()

    assert %{"version" => pinned} = Enum.at(blocks(slug), 2)
    assert pinned == published_rev
    refute pinned == draft.rev

    edit_master!(master, "Later master copy")
    view = open(conn, slug)
    assert preview(view, ref_id) =~ "Original master copy"
    refute preview(view, ref_id) =~ "Edited master copy"
    refute preview(view, ref_id) =~ "Later master copy"

    assert view
           |> element(~s([data-edit-block-id="#{ref_id}"] [data-test-id="paper-pin-master"]))
           |> render() =~ "Unpin"

    assert view
           |> element(~s([data-edit-block-id="#{ref_id}"] [data-test-id="paper-master-ref-note"]))
           |> render() =~ "Pinned to a published version"

    # ── DETACH: the pinned content comes in as plain blocks ─────────────────
    view
    |> element(~s([data-edit-block-id="#{ref_id}"] [data-test-id="paper-detach-master"]))
    |> render_click()

    assert ["lm-h", "lm-p", copy_id, "lm-sec"] = Enum.map(blocks(slug), & &1["id"])
    copy = Enum.at(blocks(slug), 2)
    refute copy_id == ref_id
    assert copy["type"] == "section"
    assert copy["master"]["mode"] == "detached"
    assert Enum.map(copy["blocks"], & &1["text"]) == ["Pricing", "Original master copy"]
    refute Enum.any?(blocks(slug), &(&1["type"] == "master-ref"))
  end

  # task-59be65118320fa0e item 2: a master-ref NESTED inside a section or a
  # column renders its master in Studio edit mode, from the same per-read
  # render map (which already walks every depth, batched per level).
  test "a linked instance nested in a section or a column previews its master",
       %{conn: conn, paper: paper, master: master} do
    slug = "paper-linked-nested-#{System.unique_integer([:positive])}"
    mid = Masters.master_id(master)
    nested = fn id -> %{"id" => id, "type" => "master-ref", "master" => mid, "version" => nil} end

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [
            %{"id" => "ln-h", "type" => "heading", "level" => 1, "text" => "Nested paper"},
            %{
              "id" => "ln-sec",
              "type" => "section",
              "title" => "Holder",
              "blocks" => [
                %{"id" => "ln-p", "type" => "paragraph", "text" => "Section intro."},
                nested.("ln-in-section")
              ]
            },
            %{
              "id" => "ln-cols",
              "type" => "columns",
              "columns" => [
                [%{"id" => "ln-c0", "type" => "paragraph", "text" => "Left."}],
                [nested.("ln-in-column")]
              ]
            }
          ]
        })
        |> Map.merge(%{"workspace_id" => paper.workspace_id, "project_id" => paper.project_id})
      )

    view = open(conn, slug)

    for id <- ["ln-in-section", "ln-in-column"] do
      html =
        view
        |> element(~s([data-test-id="paper-master-ref-preview"][data-master-ref-id="#{id}"]))
        |> render()

      assert html =~ "Original master copy"
      refute html =~ "Linked master"
    end
  end

  test "an instance of a foreign-tenant master previews as unavailable and cannot be detached",
       %{conn: conn, slug: slug} do
    other_ws = Barkpark.TenancyFixtures.create_workspace!()
    other_project = Barkpark.TenancyFixtures.create_project!(other_ws)
    foreign_slug = "paper-linked-foreign-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: foreign_slug,
          dataset: @dataset,
          blocks: [@section]
        })
        |> Map.merge(%{"workspace_id" => other_ws.id, "project_id" => other_project.id})
      )

    {:ok, foreign} =
      Masters.save_master(foreign_slug, "lm-sec", @dataset,
        workspace_id: other_ws.id,
        project_id: other_project.id
      )

    edit_master!(foreign, "Foreign secret copy")

    # A raw write can name any id; the reference must still not resolve.
    view = open(conn, slug)

    render_hook(view, "paper-ops", %{
      "ops" => [
        %{
          "op" => "insert-after",
          "afterId" => "lm-p",
          "block" => %{
            "id" => "lm-foreign",
            "type" => "master-ref",
            "master" => Masters.master_id(foreign),
            "version" => nil
          }
        }
      ],
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => assigns(view).paper_rev
    })

    assert Enum.any?(blocks(slug), &(&1["id"] == "lm-foreign"))

    view = open(conn, slug)
    html = preview(view, "lm-foreign")
    assert html =~ "Master unavailable"
    refute html =~ "Foreign secret copy"
    refute html =~ "Pricing"

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-detach-master", %{
      "block_id" => "lm-foreign",
      "request_id" => request_id,
      "if_rev" => assigns(view).paper_rev
    })

    assert_reply(view, %{saved: false, rejected: "master_not_found", request_id: ^request_id})
    assert Enum.at(blocks(slug), 2)["type"] == "master-ref"
  end

  # task-881d4b6e857b1b65: a master with NO published revision (withdrawn by
  # unpublish, or created as a draft through another door) cannot be pinned —
  # there is no version the public reader could show. Refused with a reason.
  test "Pin of an instance whose master has no published revision is refused with a reason",
       %{conn: conn, slug: slug, paper: paper, master: master} do
    view = open(conn, slug)
    insert_linked!(view, master)
    ref_id = Enum.at(blocks(slug), 2)["id"]

    {:ok, _} =
      Content.unpublish_document(Masters.master_id(master), Masters.type_name(), @dataset,
        workspace_id: paper.workspace_id,
        project_id: paper.project_id
      )

    view = open(conn, slug)
    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-pin-master", %{
      "block_id" => ref_id,
      "pin" => "true",
      "request_id" => request_id,
      "if_rev" => assigns(view).paper_rev
    })

    assert_reply(view, %{saved: false, rejected: "master_unpublished", request_id: ^request_id})
    assert render(view) =~ "Publish the master before pinning"
    assert %{"type" => "master-ref", "version" => nil} = Enum.at(blocks(slug), 2)
  end

  # task-01c812041613a8d3 (0010 §5b): Detach copies the PUBLISHED version the
  # public reader shows, never the master's unpublished draft that the
  # unpinned edit-mode preview follows. The copy is published with the paper,
  # and Detach needs write access to the paper only.
  test "Detach of an unpinned instance while the master has an unpublished draft copies the published version",
       %{conn: conn, slug: slug, master: master} do
    view = open(conn, slug)
    insert_linked!(view, master)
    ref_id = Enum.at(blocks(slug), 2)["id"]
    edit_master!(master, "Unpublished draft copy")

    view = open(conn, slug)
    assert preview(view, ref_id) =~ "Unpublished draft copy"

    button =
      view
      |> element(~s([data-edit-block-id="#{ref_id}"] [data-test-id="paper-detach-master"]))

    assert render(button) =~ "published version readers see"
    render_click(button)

    copy = Enum.at(blocks(slug), 2)
    assert copy["type"] == "section"

    assert copy["master"] == %{
             "id" => Masters.master_id(master),
             "rev" => master.rev,
             "mode" => "detached"
           }

    assert Enum.map(copy["blocks"], & &1["text"]) == ["Pricing", "Original master copy"]
    refute inspect(blocks(slug)) =~ "Unpublished draft copy"
  end

  test "Detach of an instance whose master has no published revision is refused with a reason",
       %{conn: conn, slug: slug, paper: paper, master: master} do
    view = open(conn, slug)
    insert_linked!(view, master)
    ref_id = Enum.at(blocks(slug), 2)["id"]

    {:ok, _} =
      Content.unpublish_document(Masters.master_id(master), Masters.type_name(), @dataset,
        workspace_id: paper.workspace_id,
        project_id: paper.project_id
      )

    view = open(conn, slug)
    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-detach-master", %{
      "block_id" => ref_id,
      "request_id" => request_id,
      "if_rev" => assigns(view).paper_rev
    })

    assert_reply(view, %{saved: false, rejected: "master_unpublished", request_id: ^request_id})
    assert render(view) =~ "Publish the master before detaching"
    assert %{"type" => "master-ref", "version" => nil} = Enum.at(blocks(slug), 2)
  end

  test "with the Bulldocs plugin disabled, no Pin/Detach renders and both events refuse",
       %{conn: conn, slug: slug, paper: paper, master: master} do
    view = open(conn, slug)
    insert_linked!(view, master)
    ref_id = Enum.at(blocks(slug), 2)["id"]

    {:ok, _} =
      Barkpark.Tenancy.set_workspace_plugin_settings(paper.workspace_id, %{
        "bulldocs" => %{"enabled" => false}
      })

    view = open(conn, slug)
    refute has_element?(view, ~s([data-test-id="paper-pin-master"]))
    refute has_element?(view, ~s([data-test-id="paper-detach-master"]))
    assert preview(view, ref_id) =~ "Master unavailable"

    render_hook(view, "paper-pin-master", %{"block_id" => ref_id, "pin" => "true"})
    assert_reply(view, %{saved: false, rejected: "masters_unavailable"})

    render_hook(view, "paper-detach-master", %{"block_id" => ref_id})
    assert_reply(view, %{saved: false, rejected: "masters_unavailable"})

    assert Process.alive?(view.pid)
    assert Enum.at(blocks(slug), 2)["type"] == "master-ref"
  end
end
