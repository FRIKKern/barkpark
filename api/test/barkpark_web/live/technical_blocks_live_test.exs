defmodule BarkparkWeb.TechnicalBlocksLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

    slug = "technical-controls-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: seed_blocks()
        })
      )

    raw = "technical-writer-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(raw, "technical control writer", @dataset, ["read", "write"])

    %{slug: slug, writer: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  for host <- [:public, :studio] do
    @host host

    test "#{host} route and API endpoint forms persist typed edits and parameter actions", ctx do
      blocks = [
        %{
          "id" => "route",
          "type" => "route",
          "polyline" => "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
          "distance" => 12,
          "caption" => "Before",
          "tracking" => "keep-route"
        },
        %{
          "id" => "endpoint",
          "type" => "api-endpoint",
          "method" => "M-SEARCH",
          "path" => "/before",
          "params" => [
            %{
              "name" => "q",
              "in" => "query",
              "type" => "string",
              "required" => " TRUE ",
              "hint" => "keep-param"
            },
            "legacy parameter"
          ],
          "tracking" => "keep-api"
        }
      ]

      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: ctx.slug,
            dataset: @dataset,
            blocks: blocks
          })
        )

      view = mount_editor(ctx, @host)
      assert has_element?(view, "#route-form-route")
      assert has_element?(view, "#api-endpoint-form-endpoint")
      save(view, "route", %{"distance" => "12", "caption" => "Saved route", "sport" => "cycling"})

      save(view, "endpoint", %{
        "method" => "PATCH",
        "path" => "/after",
        "param-count" => "2",
        "param-0-required" => "true"
      })

      assert stored(ctx)["route"]["distance"] === 12
      assert stored(ctx)["route"]["caption"] == "Saved route"
      assert stored(ctx)["route"]["tracking"] == "keep-route"
      assert stored(ctx)["endpoint"]["method"] == "PATCH"
      assert stored(ctx)["endpoint"]["tracking"] == "keep-api"
      assert hd(stored(ctx)["endpoint"]["params"])["required"] == " TRUE "

      submit(view, "endpoint", %{"param-count" => "2", "param-action" => "add"})

      submit(view, "endpoint", %{
        "param-count" => "3",
        "param-2-name" => "limit",
        "param-2-required" => "true",
        "param-action" => "up:2"
      })

      assert [original, %{"name" => "limit", "required" => true}, "legacy parameter"] =
               stored(ctx)["endpoint"]["params"]

      assert original["hint"] == "keep-param"
      submit(view, "endpoint", %{"param-count" => "3", "param-action" => "remove:2"})

      expected = stored(ctx)
      reloaded = mount_editor(ctx, @host)
      assert stored(ctx) == expected

      assert has_element?(
               reloaded,
               ~s(#route-form-route input[name="caption"][value="Saved route"])
             )

      assert has_element?(
               reloaded,
               ~s(#api-endpoint-form-endpoint input[name="path"][value="/after"])
             )

      assert has_element?(
               reloaded,
               ~s(#api-endpoint-form-endpoint input[name="param-1-name"][value="limit"])
             )

      assert has_element?(
               reloaded,
               ~s(#api-endpoint-form-endpoint input[name="param-1-required"][type="checkbox"][checked])
             )
    end

    test "#{host} technical form edits persist through a fresh mount", ctx do
      view = mount_editor(ctx, @host)

      for id <- ~w(diff tree notes tabs) do
        assert has_element?(view, "#technical-block-form-#{id}")
      end

      save(view, "diff", %{"file" => "src/new.ex", "lang" => "elixir", "diff" => "+new"})
      save(view, "tree", %{"text" => "src/\n  new.ex", "legend" => ""})

      save(view, "notes", %{
        "note-count" => "2",
        "note-0-id" => "source",
        "note-0-text" => "Revised evidence"
      })

      save(view, "tabs", %{
        "syncKey" => "",
        "tab-count" => "1",
        "tab-0-label" => "Elixir",
        "tab-0-language" => "elixir",
        "tab-0-value" => "IO.puts(:saved)"
      })

      expected = %{
        "diff" => %{
          "id" => "diff",
          "type" => "diff",
          "file" => "src/new.ex",
          "lang" => "elixir",
          "diff" => "+new",
          "source_key" => "keep-diff"
        },
        "tree" => %{
          "id" => "tree",
          "type" => "filetree",
          "text" => "src/\n  new.ex",
          "legend" => "",
          "source_key" => "keep-tree"
        },
        "notes" => %{
          "id" => "notes",
          "type" => "footnote",
          "notes" => [
            %{"id" => "source", "text" => "Revised evidence", "href" => "/retained"},
            "legacy note"
          ]
        },
        "tabs" => %{
          "id" => "tabs",
          "type" => "code-tabs",
          "syncKey" => "",
          "tabs" => [
            %{
              "label" => "Elixir",
              "language" => "elixir",
              "code" => "IO.puts(:saved)",
              "theme" => "retained"
            }
          ]
        }
      }

      assert stored(ctx) == expected
      reloaded = mount_editor(ctx, @host)
      assert stored(ctx) == expected

      assert has_element?(
               reloaded,
               ~s(#technical-block-form-diff input[name="file"][value="src/new.ex"])
             )

      assert has_element?(
               reloaded,
               ~s(#technical-block-form-tabs textarea[name="tab-0-value"]),
               "IO.puts(:saved)"
             )

      assert has_element?(
               reloaded,
               ~s(#technical-block-form-notes [data-test-id="note-legacy-row"]),
               "retained"
             )

      tree_input =
        reloaded
        |> element(~s(#technical-block-form-tree textarea[name="text"]))
        |> render()
        |> LazyHTML.from_fragment()

      assert LazyHTML.text(tree_input) == "src/\n  new.ex"

      assert has_element?(
               reloaded,
               ~s(#technical-block-form-notes textarea[name="note-0-text"]),
               "Revised evidence"
             )
    end

    test "#{host} technical collection actions add, reorder, and remove retained rows", ctx do
      view = mount_editor(ctx, @host)
      original = stored(ctx)

      submit(view, "notes", %{"note-count" => "2", "note-action" => "add"})
      assert length(stored(ctx)["notes"]["notes"]) == 3
      assert Enum.take(stored(ctx)["notes"]["notes"], 2) == original["notes"]["notes"]

      submit(view, "notes", %{
        "note-count" => "3",
        "note-2-id" => "new",
        "note-2-text" => "New note",
        "note-action" => "up:2"
      })

      assert [first_note, %{"id" => "new", "text" => "New note"}, "legacy note"] =
               stored(ctx)["notes"]["notes"]

      assert first_note == hd(original["notes"]["notes"])

      submit(view, "notes", %{"note-count" => "3", "note-action" => "remove:2"})
      assert length(stored(ctx)["notes"]["notes"]) == 2

      submit(view, "tabs", %{"tab-count" => "1", "tab-action" => "add"})
      assert length(stored(ctx)["tabs"]["tabs"]) == 2

      submit(view, "tabs", %{
        "tab-count" => "2",
        "tab-1-label" => "New tab",
        "tab-1-value" => "new code",
        "tab-action" => "up:1"
      })

      assert [%{"label" => "New tab", "value" => "new code"}, old_tab] =
               stored(ctx)["tabs"]["tabs"]

      assert old_tab == hd(original["tabs"]["tabs"])
      submit(view, "tabs", %{"tab-count" => "2", "tab-action" => "remove:1"})

      expected = stored(ctx)
      reloaded = mount_editor(ctx, @host)
      assert stored(ctx) == expected

      assert has_element?(
               reloaded,
               ~s(#technical-block-form-tabs input[name="tab-count"][value="1"])
             )

      assert has_element?(
               reloaded,
               ~s(#technical-block-form-notes input[name="note-count"][value="2"])
             )
    end

    test "#{host} rejects incomplete technical collection payloads without changing storage",
         ctx do
      view = mount_editor(ctx, @host)
      before = stored(ctx)

      for {id, params} <- [
            {"notes", %{"note-count" => "1", "note-0-text" => "must not save"}},
            {"tabs", %{"tab-0-value" => "must not save"}},
            {"tabs", %{"tab-action" => "remove:0"}}
          ] do
        request_id = Ecto.UUID.generate()
        render_hook(view, "paper-block-autosave", wire(view, id, params, request_id))
        assert_reply(view, %{saved: false, request_id: ^request_id})
        assert stored(ctx) == before
      end
    end

    test "#{host} toc and criteria progress fields persist through a fresh mount", ctx do
      replace_blocks(ctx, progress_navigation_blocks())
      view = mount_editor(ctx, @host)

      assert has_element?(view, "#toc-form-toc")
      assert has_element?(view, "#criteria-progress-form-criteria")

      save(view, "toc", %{
        "depth" => "4",
        "numbered" => "true",
        "sticky" => "true",
        "toc-count" => "2",
        "toc-0-text" => "Overview",
        "toc-0-level" => "3",
        "toc-0-anchor" => "overview"
      })

      save(view, "criteria", %{
        "detail" => "total",
        "criterion-count" => "2",
        "criterion-0-label" => "Published",
        "criterion-0-met" => "2.5",
        "criterion-0-total" => "6"
      })

      assert stored(ctx)["toc"] == %{
               "id" => "toc",
               "type" => "toc",
               "depth" => 4,
               "numbered" => true,
               "sticky" => true,
               "items" => [
                 %{
                   "text" => "Overview",
                   "level" => 3,
                   "anchor" => "overview",
                   "source_key" => "keep-toc"
                 },
                 "legacy toc entry"
               ]
             }

      assert stored(ctx)["criteria"] == %{
               "id" => "criteria",
               "type" => "criteria-progress",
               "detail" => "total",
               "rows" => [
                 %{
                   "label" => "Published",
                   "met" => 2.5,
                   "total" => 6,
                   "source_key" => "keep-criterion"
                 },
                 "legacy criterion"
               ]
             }

      expected = stored(ctx)
      reloaded = mount_editor(ctx, @host)
      assert stored(ctx) == expected

      assert has_element?(reloaded, ~s(#toc-form-toc input[name="depth"][value="4"]))

      assert has_element?(
               reloaded,
               ~s(#toc-form-toc input[name="numbered"][type="checkbox"][checked])
             )

      assert has_element?(
               reloaded,
               ~s(#toc-form-toc input[name="toc-0-text"][value="Overview"])
             )

      assert has_element?(
               reloaded,
               ~s(#criteria-progress-form-criteria input[name="detail"][value="total"])
             )

      assert has_element?(
               reloaded,
               ~s(#criteria-progress-form-criteria input[name="criterion-0-met"][value="2.5"])
             )
    end

    test "#{host} toc and criteria progress rows add, reorder, and remove", ctx do
      replace_blocks(ctx, progress_navigation_blocks())
      view = mount_editor(ctx, @host)

      submit(view, "toc", %{"toc-count" => "2", "toc-action" => "add"})

      submit(view, "toc", %{
        "toc-count" => "3",
        "toc-2-text" => "Added",
        "toc-2-level" => "2",
        "toc-2-anchor" => "added",
        "toc-action" => "up:2"
      })

      assert [original_toc, added_toc, "legacy toc entry"] = stored(ctx)["toc"]["items"]
      assert original_toc["source_key"] == "keep-toc"
      assert added_toc == %{"text" => "Added", "level" => 2, "anchor" => "added"}

      submit(view, "toc", %{"toc-count" => "3", "toc-action" => "remove:2"})

      submit(view, "criteria", %{
        "criterion-count" => "2",
        "criterion-action" => "add"
      })

      submit(view, "criteria", %{
        "criterion-count" => "3",
        "criterion-2-label" => "Added",
        "criterion-2-met" => "1.5",
        "criterion-2-total" => "2",
        "criterion-action" => "up:2"
      })

      assert [original_criterion, added_criterion, "legacy criterion"] =
               stored(ctx)["criteria"]["rows"]

      assert original_criterion["source_key"] == "keep-criterion"
      assert added_criterion == %{"label" => "Added", "met" => 1.5, "total" => 2}

      submit(view, "criteria", %{
        "criterion-count" => "3",
        "criterion-action" => "remove:2"
      })

      expected = stored(ctx)
      reloaded = mount_editor(ctx, @host)
      assert stored(ctx) == expected
      assert has_element?(reloaded, ~s(#toc-form-toc input[name="toc-count"][value="2"]))

      assert has_element?(
               reloaded,
               ~s(#criteria-progress-form-criteria input[name="criterion-count"][value="2"])
             )

      assert has_element?(reloaded, ~s(#toc-form-toc input[name="toc-1-text"][value="Added"]))

      assert has_element?(
               reloaded,
               ~s(#criteria-progress-form-criteria input[name="criterion-1-label"][value="Added"])
             )
    end

    test "#{host} rejects invalid toc and criteria progress numbers and counts", ctx do
      replace_blocks(ctx, progress_navigation_blocks())
      view = mount_editor(ctx, @host)
      before = stored(ctx)

      for {id, params} <- [
            {"toc", %{"depth" => "0"}},
            {"toc", %{"toc-count" => "2", "toc-0-level" => "invalid"}},
            {"toc", %{"toc-count" => "1", "toc-action" => "remove:0"}},
            {"criteria", %{"criterion-count" => "2", "criterion-0-met" => "NaN"}},
            {"criteria", %{"criterion-count" => "1", "criterion-action" => "remove:0"}}
          ] do
        request_id = Ecto.UUID.generate()
        render_hook(view, "paper-block-autosave", wire(view, id, params, request_id))
        assert_reply(view, %{saved: false, request_id: ^request_id})
        assert stored(ctx) == before
      end

      reloaded = mount_editor(ctx, @host)
      assert stored(ctx) == before
      assert has_element?(reloaded, ~s(#toc-form-toc input[name="depth"][value="2"]))

      assert has_element?(
               reloaded,
               ~s(#criteria-progress-form-criteria input[name="criterion-0-met"][value="1"])
             )
    end
  end

  defp mount_editor(ctx, :studio) do
    {:ok, view, _html} = live(ctx.conn, scoped_studio("/d/#{@dataset}/studio/paper/#{ctx.slug}"))
    view
  end

  defp mount_editor(ctx, :public) do
    {:ok, view, _html} = live(ctx.writer, "/papers/#{ctx.slug}")
    render_click(view, "paper-toggle-edit", %{})
    view
  end

  defp save(view, id, params) do
    request_id = Ecto.UUID.generate()
    render_hook(view, "paper-block-autosave", wire(view, id, params, request_id))
    assert_reply(view, %{saved: true, request_id: ^request_id})
  end

  defp wire(view, id, params, request_id) do
    Map.merge(params, %{
      "block_id" => id,
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev,
      "request_id" => request_id
    })
  end

  defp submit(view, id, params) do
    request_id = Ecto.UUID.generate()
    render_hook(view, "paper-edit-block", wire(view, id, params, request_id))
    assert_reply(view, %{saved: true, request_id: ^request_id})
  end

  defp stored(ctx), do: Map.new(Content.paper_blocks(ctx.slug, @dataset), &{&1["id"], &1})

  defp replace_blocks(ctx, blocks) do
    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: ctx.slug,
          dataset: @dataset,
          blocks: blocks
        })
      )
  end

  defp progress_navigation_blocks do
    [
      %{
        "id" => "toc",
        "type" => "toc",
        "depth" => 2,
        "numbered" => false,
        "sticky" => false,
        "items" => [
          %{
            "text" => "Before",
            "level" => 1,
            "anchor" => "before",
            "source_key" => "keep-toc"
          },
          "legacy toc entry"
        ]
      },
      %{
        "id" => "criteria",
        "type" => "criteria-progress",
        "detail" => "rows",
        "rows" => [
          %{
            "label" => "Before",
            "met" => 1,
            "total" => 4,
            "source_key" => "keep-criterion"
          },
          "legacy criterion"
        ]
      }
    ]
  end

  defp seed_blocks do
    [
      %{
        "id" => "diff",
        "type" => "diff",
        "file" => "old.ex",
        "lang" => "",
        "diff" => "+old",
        "source_key" => "keep-diff"
      },
      %{
        "id" => "tree",
        "type" => "filetree",
        "text" => "old/",
        "legend" => "Old legend",
        "source_key" => "keep-tree"
      },
      %{
        "id" => "notes",
        "type" => "footnote",
        "notes" => [
          %{"id" => "old", "text" => "Old evidence", "href" => "/retained"},
          "legacy note"
        ]
      },
      %{
        "id" => "tabs",
        "type" => "code-tabs",
        "syncKey" => "install",
        "tabs" => [%{"label" => "Code", "language" => "", "code" => "old", "theme" => "retained"}]
      }
    ]
  end
end
