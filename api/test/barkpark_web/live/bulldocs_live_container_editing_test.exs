defmodule BarkparkWeb.BulldocsLiveContainerEditingTest do
  @moduledoc """
  Public-reader regressions for the structured paper-links and expandable
  editors. These exercise the mounted route, its real form event names, and
  the canonical nested block-op wire before proving storage on a fresh mount.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    suffix = System.unique_integer([:positive])
    ws = create_workspace!("reader-container-edit-#{suffix}")
    project = create_project!(ws)
    slug = "reader-container-edit-#{suffix}"

    blocks = fixture_blocks()

    assert {:ok, _paper} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{
                 "slug" => slug,
                 "title" => "Container editor #{suffix}",
                 "workspace_id" => ws.id,
                 "project_id" => project.id,
                 "blocks" => blocks
               })
             )

    raw = "reader-container-writer-#{suffix}"

    {:ok, _token} =
      Auth.create_token(raw, "reader container writer", @dataset, ["read", "write"], ws.id)

    %{
      conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
      raw: raw,
      ws: ws,
      project: project,
      slug: slug,
      blocks: blocks
    }
  end

  test "paper-links form preserves authored and unknown reference metadata after reload", ctx do
    path = paper_path(ctx)
    before_toggle = stored_blocks(ctx)
    {:ok, view, _html} = live(ctx.conn, path)

    editing = render_click(view, "paper-toggle-edit", %{})
    assert stored_blocks(ctx) == before_toggle
    refute editing =~ "paper-links blocks are not editable yet"
    assert has_element?(view, "#paper-links-form-links")
    assert has_element?(view, ~s(#paper-links-form-links input[name="ref-0-title"]))
    assert has_element?(view, ~s(#paper-links-form-links button[value="remove:1"]))

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "links",
      "title" => "Updated journey",
      "description" => "Updated authored description",
      "layout" => "chapters",
      "ref-count" => "2",
      "ref-0-slug" => "day-one",
      "ref-0-title" => "Edited Day One",
      "ref-0-description" => "Edited reference copy",
      "ref-0-eyebrow" => "01 Sep",
      "ref-0-meta" => "82 changes",
      "ref-0-reason" => "Why this day matters",
      "ref-0-prefer-authored-copy" => "true",
      "ref-1-slug" => "legacy-updated",
      "ref-action" => "",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => Ecto.UUID.generate()
    })

    links = stored_block(ctx, "links")
    assert links["title"] == "Updated journey"
    assert links["description"] == "Updated authored description"
    assert links["layout"] == "chapters"

    assert [first, "legacy-updated"] = links["refs"]
    assert first["title"] == "Edited Day One"
    assert first["description"] == "Edited reference copy"
    assert first["eyebrow"] == "01 Sep"
    assert first["meta"] == "82 changes"
    assert first["reason"] == "Why this day matters"
    assert first["prefer_authored_copy"] == true
    assert first["analytics_key"] == "keep-me"

    remove_request_id = Ecto.UUID.generate()

    render_hook(view, "paper-edit-block", %{
      "block_id" => "links",
      "title" => "Updated journey",
      "description" => "Updated authored description",
      "layout" => "chapters",
      "ref-count" => "2",
      "ref-0-slug" => "day-one",
      "ref-0-title" => "Edited Day One",
      "ref-0-description" => "Edited reference copy",
      "ref-0-eyebrow" => "01 Sep",
      "ref-0-meta" => "82 changes",
      "ref-0-reason" => "Why this day matters",
      "ref-0-prefer-authored-copy" => "true",
      "ref-1-slug" => "legacy-updated",
      "ref-action" => "remove:1",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => remove_request_id
    })

    assert_reply(view, %{saved: true, request_id: ^remove_request_id})
    assert [remaining] = stored_block(ctx, "links")["refs"]
    assert remaining["analytics_key"] == "keep-me"

    reloaded = remount_edit(ctx, path)

    assert Enum.find(socket_of(reloaded).assigns.edit_blocks, &(&1["id"] == "links")) ==
             stored_block(ctx, "links")
  end

  test "malformed or stale expandable run context fails closed without mutation", ctx do
    path = paper_path(ctx)
    {:ok, view, _html} = live(ctx.conn, path)
    render_click(view, "paper-toggle-edit", %{})
    before = stored_blocks(ctx)

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "ops" => [
        %{"op" => "patch-block", "id" => "child-rich", "patch" => %{"content" => []}}
      ],
      "container_id" => "details",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => request_id
    })

    assert_reply(view, %{saved: false, request_id: ^request_id})
    assert stored_blocks(ctx) == before

    stale_request_id = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "ops" => [
        %{"op" => "patch-block", "id" => "child-rich", "patch" => %{"content" => []}}
      ],
      "container_id" => "details",
      "container_run_ids" => ["not-the-confirmed-run"],
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => stale_request_id
    })

    assert_reply(view, %{saved: false, request_id: ^stale_request_id})
    assert stored_blocks(ctx) == before
  end

  test "expandable chrome and nested rich children persist without changing their container alias",
       ctx do
    path = paper_path(ctx)
    {:ok, view, _html} = live(ctx.conn, path)
    editing = render_click(view, "paper-toggle-edit", %{})

    refute editing =~ "expandable blocks are not editable yet"
    assert has_element?(view, "#expandable-form-details")

    assert has_element?(
             view,
             ~s([data-test-id="paper-expandable-children"] [data-canvas-blocks*="child-rich"])
           )

    assert has_element?(
             view,
             ~s([data-test-id="paper-expandable-children"] [data-canvas-blocks*="stats"])
           )

    assert has_element?(
             view,
             ~s([data-test-id="paper-expandable-children"] [data-canvas-blocks*="cards"])
           )

    assert has_element?(
             view,
             ~s([data-test-id="paper-expandable-children"] [data-canvas-blocks*="lineage"])
           )

    assert has_element?(view, "#bar-chart-form-nested-chart")

    assert has_element?(
             view,
             ~s([data-test-id="paper-expandable-children"] [data-canvas-blocks*="legacy-child"])
           )

    original_children = stored_block(ctx, "details")["children"]

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "details",
      "summary" => "Updated technical record",
      "open" => "true",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => Ecto.UUID.generate()
    })

    details = stored_block(ctx, "details")
    assert details["summary"] == "Updated technical record"
    assert details["open"] == true
    assert details["children"] == original_children
    refute Map.has_key?(details, "blocks")

    marked_content = [
      %{
        "type" => "strong",
        "children" => [
          %{
            "type" => "link",
            "href" => "/papers/day-two",
            "children" => [%{"type" => "text", "value" => "Updated evidence"}]
          }
        ]
      }
    ]

    assert_saved_patch(
      view,
      "child-rich",
      %{"content" => marked_content},
      "details",
      ["child-rich", "child-code", "nested-stats"]
    )

    assert %{"children" => [%{"content" => ^marked_content} | _]} = stored_block(ctx, "details")

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "nested-chart",
      "title" => "Updated category totals",
      "max" => "900",
      "values" => "true",
      "bar-count" => "2",
      "bar-0-label" => "feat",
      "bar-0-value" => "203",
      "bar-1-label" => "fix",
      "bar-1-value" => "630",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => Ecto.UUID.generate()
    })

    chart = nested_child(stored_block(ctx, "details"), "nested-chart")
    assert chart["title"] == "Updated category totals"
    assert chart["max"] == 900
    assert chart["values"] == true
    assert [%{"label" => "feat", "value" => 203, "color" => "mint"}, _] = chart["bars"]
    assert chart["source_note"] == "preserve-chart-metadata"

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "nested-chart",
      "title" => "   ",
      "max" => "",
      "bar-count" => "2",
      "bar-0-label" => "feat",
      "bar-0-value" => "203",
      "bar-1-label" => "fix",
      "bar-1-value" => "630",
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => Ecto.UUID.generate()
    })

    cleared_chart = nested_child(stored_block(ctx, "details"), "nested-chart")
    assert cleared_chart["title"] == nil
    assert cleared_chart["max"] == nil
    assert cleared_chart["source_note"] == "preserve-chart-metadata"

    structural_request_id = Ecto.UUID.generate()
    structural_rev = socket_of(view).assigns.paper_rev

    structural_payload = %{
      "ops" => [
        %{"op" => "remove-block", "id" => "nested-cards"},
        %{"op" => "remove-block", "id" => "nested-lineage"},
        %{
          "op" => "append-block",
          "block" => %{"id" => "split-a", "type" => "paragraph", "content" => []}
        },
        %{
          "op" => "insert-after",
          "afterId" => "split-a",
          "block" => %{"id" => "split-b", "type" => "paragraph", "content" => []}
        },
        %{"op" => "move-block", "id" => "split-b", "after" => nil}
      ],
      "container_id" => "details",
      "container_run_ids" => ["nested-cards", "nested-lineage"],
      "if_rev" => structural_rev,
      "request_id" => structural_request_id
    }

    render_hook(view, "paper-ops", structural_payload)
    assert_reply(view, %{saved: true, request_id: ^structural_request_id, replayed: false})

    details_after_structure = stored_block(ctx, "details")

    assert Enum.map(details_after_structure["children"], & &1["id"]) == [
             "child-rich",
             "child-code",
             "nested-stats",
             "nested-chart",
             "split-b",
             "split-a"
           ]

    assert details_after_structure["archive_key"] == "preserve-parent-metadata"

    render_hook(view, "paper-ops", structural_payload)
    assert_reply(view, %{saved: true, request_id: ^structural_request_id, replayed: true})

    assert stored_block(ctx, "details") == details_after_structure

    assert_saved_patch(
      view,
      "legacy-child",
      %{"content" => [%{"type" => "text", "value" => "Legacy alias updated"}]},
      "legacy-details",
      ["legacy-child"]
    )

    legacy = stored_block(ctx, "legacy-details")
    assert [%{"content" => [%{"value" => "Legacy alias updated"}]}] = legacy["blocks"]
    refute Map.has_key?(legacy, "children")

    reloaded = remount_edit(ctx, path)
    reloaded_blocks = socket_of(reloaded).assigns.edit_blocks
    assert Enum.find(reloaded_blocks, &(&1["id"] == "details")) == stored_block(ctx, "details")
    assert Enum.find(reloaded_blocks, &(&1["id"] == "legacy-details")) == legacy
  end

  defp assert_saved_patch(view, id, patch, container_id, run_ids) do
    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "ops" => [%{"op" => "patch-block", "id" => id, "patch" => patch}],
      "container_id" => container_id,
      "container_run_ids" => run_ids,
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => request_id
    })

    assert_reply(view, %{saved: true, request_id: ^request_id})
  end

  defp remount_edit(ctx, path) do
    conn = Plug.Test.init_test_session(recycle(ctx.conn), %{"api_token" => ctx.raw})
    {:ok, view, _html} = live(conn, path)
    render_click(view, "paper-toggle-edit", %{})
    view
  end

  defp stored_blocks(ctx) do
    ctx.slug
    |> Content.get_paper(@dataset, workspace_id: ctx.ws.id, project_id: ctx.project.id)
    |> get_in([Access.key!(:content), "blocks"])
  end

  defp stored_block(ctx, id), do: Enum.find(stored_blocks(ctx), &(&1["id"] == id))

  defp nested_child(container, id) do
    container
    |> then(&(Map.get(&1, "children") || Map.get(&1, "blocks") || []))
    |> Enum.find(fn child -> child["id"] == id end)
  end

  defp paper_path(ctx), do: "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/papers/#{ctx.slug}"
  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp fixture_blocks do
    [
      %{
        "id" => "links",
        "type" => "paper-links",
        "title" => "Travel through the month",
        "description" => "Authored overview",
        "layout" => "timeline",
        "refs" => [
          %{
            "slug" => "day-one",
            "title" => "Day One",
            "description" => "Original reference copy",
            "eyebrow" => "01 Aug",
            "meta" => "74 changes",
            "reason" => "Original reason",
            "prefer_authored_copy" => true,
            "analytics_key" => "keep-me"
          },
          "legacy-ref"
        ]
      },
      %{
        "id" => "details",
        "type" => "expandable",
        "summary" => "Technical record",
        "open" => false,
        "children" => [
          %{
            "id" => "child-rich",
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "strong",
                "children" => [%{"type" => "text", "value" => "Original marked evidence"}]
              }
            ],
            "source_note" => "preserve-child-metadata"
          },
          %{"id" => "child-code", "type" => "code", "lang" => "sh", "value" => "echo ok"},
          %{
            "id" => "nested-stats",
            "type" => "stats",
            "items" => [%{"label" => "Changes", "value" => "1,291"}]
          },
          %{
            "id" => "nested-chart",
            "type" => "bar-chart",
            "title" => "Updates by category",
            "max" => 800,
            "values" => true,
            "bars" => [
              %{"label" => "feat", "value" => 202, "color" => "mint"},
              %{"label" => "fix", "value" => 627}
            ],
            "source_note" => "preserve-chart-metadata"
          },
          %{
            "id" => "nested-cards",
            "type" => "cards",
            "items" => [%{"title" => "Card", "body" => "Evidence"}]
          },
          %{
            "id" => "nested-lineage",
            "type" => "lineage",
            "items" => [%{"label" => "Source", "value" => "Chronicle"}]
          }
        ],
        "archive_key" => "preserve-parent-metadata"
      },
      %{
        "id" => "legacy-details",
        "type" => "expandable",
        "summary" => "Legacy alias",
        "blocks" => [
          %{
            "id" => "legacy-child",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Legacy original"}]
          }
        ]
      }
    ]
  end
end
