defmodule BarkparkWeb.BulldocsLiveEditTest do
  @moduledoc """
  Edit-on-the-link slice 2 (task-633d25cac4262afc, epic task-a19eeb215f653529):
  the paper reader offers an Edit toggle to a viewer slice 1 graded
  `can_edit?`, mounts the EXISTING Studio Beta block editor over the same paper
  surface, and routes every edit through the ONE op path.

  Acceptance criteria proved here:

    1. With `can_edit?` TRUE, editing a paragraph on `/papers/<slug>` persists
       through `apply_paper_block_op(s)` and a second ANONYMOUS tab sees the
       change live (no reload — the reader's existing `{:paper_block, …}`
       subscription carries it).
    2. With `can_edit?` FALSE, every `paper-*` edit event is refused
       SERVER-SIDE and no editor markup is rendered.

  The refusal is proved on the two shapes a denied viewer really has: fully
  anonymous, and an identified-but-read-only api token. Both are refused by the
  SAME gate (`BulldocsLive.Edit.attach_gate/1`, keyed on `:can_edit?` and
  nothing else) with the SAME copy.

  `async: false` — the Default scope and the tag registry are process-global,
  and the two-tab case needs the shared sandbox.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.BulldocsLive
  alias BarkparkWeb.BulldocsLive.Edit

  @dataset "production"

  # Every MVP editor event the reader wires, with a payload that WOULD write if
  # it reached the handler. Each is pushed at a denied socket below.
  @denied_probes [
    {"paper-toggle-edit", %{}},
    {"paper-op",
     %{
       "op" => "patch-block",
       "id" => "b-body",
       "patch" => %{"content" => [%{"type" => "text", "value" => "hijacked"}]}
     }},
    {"paper-ops",
     %{
       "ops" => [
         %{
           "op" => "patch-block",
           "id" => "b-body",
           "patch" => %{"content" => [%{"type" => "text", "value" => "hijacked"}]}
         }
       ]
     }},
    {"paper-edit-block", %{"block_id" => "b-body", "text" => "hijacked"}},
    {"paper-block-autosave", %{"block_id" => "b-body", "text" => "hijacked"}},
    {"paper-add-block", %{"block-type" => "paragraph"}},
    {"paper-delete-block", %{"id" => "b-extra"}},
    {"paper-move-block", %{"id" => "b-extra", "dir" => "up"}},
    {"paper-move-block-to", %{"id" => "b-extra", "after-id" => "b-head"}}
  ]

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {default_ws, default_proj} = ensure_default_scope!()
    slug = "eol-edit-#{System.unique_integer([:positive])}"
    seed_block_paper!(slug)

    %{conn: conn, slug: slug, default_ws: default_ws, default_proj: default_proj}
  end

  # A BLOCK paper (not body_html): the editor edits blocks, so the fixture must
  # carry them. Three blocks so a delete never trips the hollow-result ratchet.
  defp seed_block_paper!(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Edit on the link probe",
          "blocks" => [
            %{
              "id" => "b-head",
              "type" => "heading",
              "text" => "Edit on the link probe",
              "level" => 1
            },
            %{
              "id" => "b-body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Original body text"}]
            },
            %{
              "id" => "b-extra",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Spare block"}]
            }
          ]
        })
      )

    paper
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns
  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp flash_of(view), do: assigns_of(view).flash || %{}

  defp stored_blocks(slug) do
    case Content.get_public_paper(slug, @dataset) do
      %{content: %{"blocks" => blocks}} -> blocks
      _ -> nil
    end
  end

  defp block_text(slug, id) do
    slug
    |> stored_blocks()
    |> Enum.find(&(Map.get(&1, "id") == id))
    |> case do
      %{"content" => [%{"value" => value} | _]} -> value
      other -> other
    end
  end

  defp as_token(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  defp writer_conn(conn) do
    raw = "eol-writer-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "eol writer", @dataset, ["read", "write"])
    as_token(conn, raw)
  end

  # The reader converges through PubSub, not through the caller's return value —
  # poll the rendered DOM briefly rather than assuming a delivery order.
  defp eventually_renders(view, needle, tries \\ 20) do
    html = render(view)

    cond do
      html =~ needle -> html
      tries <= 0 -> flunk("never rendered #{inspect(needle)}; last render:\n#{html}")
      true -> eventually_renders(view, needle, tries - 1)
    end
  end

  describe "criterion 2 — anonymous: no editor markup, every edit event refused" do
    test "the anonymous render carries neither the toggle nor the editor", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "Original body text"
      assert assigns_of(view).can_edit? == false

      refute html =~ "studio-paper-block-editor"
      refute html =~ ~s(id="paper-edit-toggle")
      refute html =~ "paper-toggle-edit"
      # `bp-paper-editor` is a CLASS the shared paper-surface stylesheet always
      # embeds, so assert on the editor's own container id instead.
      refute html =~ ~s(id="paper-editor-#{slug}")
    end

    test "every MVP paper-* event is refused server-side and writes nothing", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      before = stored_blocks(slug)

      for {event, params} <- @denied_probes do
        render_hook(view, event, params)

        assert flash_of(view)["error"] == Edit.denial(),
               "#{event} was not refused"

        assert stored_blocks(slug) == before, "#{event} wrote to the paper"
      end

      # The toggle never flipped, so the editor never rendered.
      assert assigns_of(view).editing? == false
      refute render(view) =~ "studio-paper-block-editor"
    end

    test "the whole gated roster (incl. the events the reader does not wire) is refused",
         %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      for event <- Edit.edit_events() do
        render_hook(view, event, %{})

        assert flash_of(view)["error"] == Edit.denial(), "#{event} was not refused"
      end
    end

    test "a crafted nested-component paper_op message is refused by the write seam", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      send(view.pid, {
        :paper_op,
        %{
          "op" => "patch-block",
          "id" => "b-body",
          "patch" => %{"content" => [%{"type" => "text", "value" => "hijacked"}]}
        }
      })

      render(view)
      assert flash_of(view)["error"] == Edit.denial()
      assert block_text(slug, "b-body") == "Original body text"
    end

    test "the reader's OWN events keep working — the gate is not a blanket paper-* block",
         %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      render_hook(view, "paper-action", %{"action" => "grill"})

      # The handler ran (it acks the click inline); the gate never saw it.
      assert assigns_of(view).last_action == "grill"
      refute flash_of(view)["error"]

      render_hook(view, "rail-select", %{"event-id" => "some-event"})
      assert assigns_of(view).selected_event_id == "some-event"

      render_hook(view, "close-diff", %{})
      assert assigns_of(view).diff_open == false
    end
  end

  describe "criterion 2 — a read-only token is identified but refused identically" do
    test "no toggle, and every MVP event is refused", %{conn: conn, slug: slug} do
      raw = "eol-reader-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "eol reader", @dataset, ["read"])

      {:ok, view, html} = live(as_token(conn, raw), "/papers/#{slug}")

      assert %{kind: :token} = assigns_of(view).viewer
      assert assigns_of(view).can_edit? == false
      refute html =~ ~s(id="paper-edit-toggle")

      before = stored_blocks(slug)

      for {event, params} <- @denied_probes do
        render_hook(view, event, params)

        assert flash_of(view)["error"] == Edit.denial(), "#{event} was not refused"
        assert stored_blocks(slug) == before, "#{event} wrote to the paper"
      end

      refute render(view) =~ "studio-paper-block-editor"
    end

    test "a forged correlated component message acknowledges refusal as unsaved", %{
      conn: conn,
      slug: slug
    } do
      raw = "eol-reader-field-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "eol field reader", @dataset, ["read"])
      {:ok, view, _html} = live(as_token(conn, raw), "/papers/#{slug}")
      before = stored_blocks(slug)

      send(view.pid, {
        :paper_op,
        %{
          "op" => "patch-block",
          "id" => "b-body",
          "patch" => %{"content" => [%{"type" => "text", "value" => "Denied"}]}
        },
        "denied-field-request"
      })

      assert_push_event(view, "bp:paper-field-save-result", %{
        request_id: "denied-field-request",
        saved: false
      })

      assert stored_blocks(slug) == before
      assert flash_of(view)["error"] == Edit.denial()
    end
  end

  describe "item-share confinement" do
    test "canvas autocomplete never widens a one-paper share into dataset discovery" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          viewer: %{kind: :user, id: "signed-in-outsider"},
          paper_share_grant: %{grant: :item}
        }
      }

      assert {:reply, %{results: []}, ^socket} =
               BulldocsLive.handle_event("paper-wikilink-search", %{"query" => "secret"}, socket)

      assert {:reply, %{results: []}, ^socket} =
               BulldocsLive.handle_event("paper-tag-search", %{"query" => "secret"}, socket)
    end
  end

  describe "criterion 1 — a member holding write edits on the link" do
    test "the toggle renders, and it mounts the Studio Beta block editor", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, html} = live(writer_conn(conn), "/papers/#{slug}")

      assert assigns_of(view).can_edit? == true
      assert html =~ ~s(id="paper-edit-toggle")
      assert html =~ ~s(phx-hook="BarkparkPaperEditToggle")
      assert html =~ ~s(data-editing="false")
      assert toggle_label(html) == "Edit"
      refute html =~ "studio-paper-block-editor"

      editing = render_click(view, "paper-toggle-edit", %{})

      assert editing =~ ~s(data-test-id="studio-paper-block-editor")
      assert editing =~ ~s(id="paper-editor-#{slug}")
      assert editing =~ ~s(data-test-id="paper-canvas-run")
      assert editing =~ ~s(<bp-paper-canvas)
      assert editing =~ ~s(data-canvas-picker-browse="true")
      assert editing =~ ~s(data-editing="true")
      assert assigns_of(view).editing? == true
      # The toggle now reads View.
      assert toggle_label(editing) == "View"

      # Toggling back restores the reader article, editor gone.
      viewing = render_click(view, "paper-toggle-edit", %{})
      refute viewing =~ "studio-paper-block-editor"
      assert viewing =~ "Original body text"
      assert assigns_of(view).editing? == false
    end

    test "the scoped reader carries its workspace and project prefix into the canvas", %{
      conn: conn,
      slug: slug,
      default_ws: ws,
      default_proj: proj
    } do
      {:ok, view, _html} =
        live(writer_conn(conn), "/w/#{ws.slug}/p/#{proj.slug}/papers/#{slug}")

      editing = render_click(view, "paper-toggle-edit", %{})

      assert editing =~ ~s(data-canvas-scope-prefix="/w/#{ws.slug}/p/#{proj.slug}")
      assert editing =~ ~s(data-canvas-picker-browse="true")
    end

    test "a paper-op patch-block on a paragraph persists AND a second anonymous tab sees it live",
         %{conn: conn, slug: slug} do
      {:ok, editor, _html} = live(writer_conn(conn), "/papers/#{slug}")

      # A second, entirely ANONYMOUS reader already on the same URL.
      {:ok, reader, reader_html} = live(scoped_conn(), "/papers/#{slug}")
      assert reader_html =~ "Original body text"
      assert assigns_of(reader).can_edit? == false

      render_click(editor, "paper-toggle-edit", %{})

      render_hook(editor, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-body",
        "patch" => %{"content" => [%{"type" => "text", "value" => "Edited on the link"}]}
      })

      # Persisted through the ONE op path.
      assert block_text(slug, "b-body") == "Edited on the link"
      assert assigns_of(editor).save_status == "Auto-saved"
      assert assigns_of(editor).paper_halt == nil
      refute flash_of(editor)["error"]

      # Re-derived editor buffer.
      assert Enum.find(assigns_of(editor).edit_blocks, &(&1["id"] == "b-body"))["content"] == [
               %{"type" => "text", "value" => "Edited on the link"}
             ]

      # And the anonymous tab converged without a remount.
      reader_pid = reader.pid
      assert eventually_renders(reader, "Edited on the link")
      assert reader.pid == reader_pid
      assert render(reader) =~ ~s(id="paper-sentinel")
    end

    test "a correlated component paper_op persists and acknowledges the exact save", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      send(view.pid, {
        :paper_op,
        %{
          "op" => "patch-block",
          "id" => "b-body",
          "patch" => %{
            "content" => [%{"type" => "text", "value" => "Correlated field save"}]
          }
        },
        "field-request-accepted"
      })

      # Synchronize with the handler before asserting its asynchronously pushed reply.
      render(view)

      assert_push_event(view, "bp:paper-field-save-result", %{
        request_id: "field-request-accepted",
        saved: true
      })

      assert block_text(slug, "b-body") == "Correlated field save"
      assert assigns_of(view).save_status == "Auto-saved"
      assert assigns_of(view).last_save_ok? == true
      refute flash_of(view)["error"]
    end

    test "a paper-ops batch folds atomically through apply_paper_block_ops", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "b-body",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Batch body"}]}
          },
          %{
            "op" => "patch-block",
            "id" => "b-extra",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Batch extra"}]}
          }
        ]
      })

      assert block_text(slug, "b-body") == "Batch body"
      assert block_text(slug, "b-extra") == "Batch extra"
      assert assigns_of(view).save_status == "Auto-saved"
      refute flash_of(view)["error"]

      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: run_id, blocks: echoed}] = runs
      assert run_id == "#{slug}-run-0"

      assert Enum.find(echoed, &(&1["id"] == "b-body"))["content"] == [
               %{"type" => "text", "value" => "Batch body"}
             ]

      {:ok, reloaded, _html} = live(writer_conn(conn), "/papers/#{slug}")
      reload_html = render_click(reloaded, "paper-toggle-edit", %{})
      assert reload_html =~ "Batch body"
      assert reload_html =~ ~s(data-test-id="paper-canvas-run")
    end

    test "paper-ops invalid payloads reject a prior successful save without mutating", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "b-body",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Saved first"}]}
          }
        ]
      })

      assert assigns_of(view).last_save_ok? == true
      assert block_text(slug, "b-body") == "Saved first"
      before = stored_blocks(slug)

      valid_ops = [
        %{
          "op" => "patch-block",
          "id" => "b-body",
          "patch" => %{"content" => [%{"type" => "text", "value" => "Must not land"}]}
        }
      ]

      invalid_payloads = [
        %{"request_id" => Ecto.UUID.generate(), "ops" => []},
        %{"request_id" => Ecto.UUID.generate(), "ops" => "not-a-list"},
        %{"ops" => valid_ops},
        %{"request_id" => "not-a-uuid", "ops" => valid_ops},
        %{}
      ]

      Enum.reduce(invalid_payloads, socket_of(view), fn params, socket ->
        assert {:reply, %{saved: false}, rejected_socket} =
                 BulldocsLive.handle_event("paper-ops", params, socket)

        assert rejected_socket.assigns.last_save_ok? == false
        assert rejected_socket.assigns.save_status == "Save failed"
        assert stored_blocks(slug) == before
        rejected_socket
      end)
    end

    test "single-op rejection cannot reuse an earlier successful acknowledgement", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})
      op = %{"op" => "patch-block", "id" => "b-body", "patch" => %{"text" => "Saved"}}

      assert {:reply, %{saved: true}, saved_socket} =
               BulldocsLive.handle_event("paper-op", op, socket_of(view))

      before = stored_blocks(slug)

      for {params, socket} <- [
            {%{}, saved_socket},
            {op, Phoenix.Component.assign(saved_socket, :can_edit?, false)},
            {op, Phoenix.Component.assign(saved_socket, :slug, nil)}
          ] do
        assert {:reply, %{saved: false}, rejected_socket} =
                 BulldocsLive.handle_event("paper-op", params, socket)

        assert rejected_socket.assigns.last_save_ok? == false
        assert rejected_socket.assigns.save_status == "Save failed"
        assert stored_blocks(slug) == before
      end
    end

    test "fallback autosave acknowledges only the current successful write", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      assert {:reply, %{saved: true}, saved_socket} =
               BulldocsLive.handle_event(
                 "paper-block-autosave",
                 %{"block_id" => "b-body", "text" => "Fallback saved"},
                 socket_of(view)
               )

      assert block_text(slug, "b-body") == "Fallback saved"
      before = stored_blocks(slug)

      for params <- [%{}, %{"block_id" => nil}] do
        assert {:reply, %{saved: false}, rejected_socket} =
                 BulldocsLive.handle_event("paper-block-autosave", params, saved_socket)

        assert rejected_socket.assigns.last_save_ok? == false
        assert rejected_socket.assigns.save_status == "Save failed"
        assert stored_blocks(slug) == before
      end

      denied_socket = Phoenix.Component.assign(saved_socket, :can_edit?, false)

      assert {:reply, %{saved: false}, rejected_socket} =
               BulldocsLive.handle_event(
                 "paper-block-autosave",
                 %{"block_id" => "b-body", "text" => "Must not land"},
                 denied_socket
               )

      assert rejected_socket.assigns.last_save_ok? == false
      assert stored_blocks(slug) == before
    end

    test "paper-ops replays one committed request and reauthorizes before replay", %{
      conn: conn,
      slug: slug
    } do
      raw = "eol-replay-writer-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "eol replay writer", @dataset, ["read", "write"])
      {:ok, view, _html} = live(as_token(conn, raw), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      request_id = Ecto.UUID.generate()

      params = %{
        "request_id" => request_id,
        "ops" => [
          %{
            "op" => "append-block",
            "block" => %{
              "id" => "replay-once",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Only once"}]
            }
          }
        ]
      }

      assert {:reply,
              %{
                saved: true,
                request_id: ^request_id,
                replayed: false,
                rev: committed_rev
              }, committed_socket} =
               BulldocsLive.handle_event("paper-ops", params, socket_of(view))

      committed_blocks = stored_blocks(slug)
      assert Enum.count(committed_blocks, &(&1["id"] == "replay-once")) == 1

      assert {:reply,
              %{
                saved: true,
                request_id: ^request_id,
                replayed: true,
                rev: ^committed_rev
              }, replayed_socket} =
               BulldocsLive.handle_event("paper-ops", params, committed_socket)

      assert stored_blocks(slug) == committed_blocks

      {:ok, _revoked} = Auth.revoke_token(token)

      assert {:reply, %{saved: false, request_id: ^request_id}, denied_socket} =
               BulldocsLive.handle_event("paper-ops", params, replayed_socket)

      assert denied_socket.assigns.last_save_ok? == false
      assert stored_blocks(slug) == committed_blocks

      assert {:reply, %{saved: false, request_id: ^request_id}, denied_again_socket} =
               BulldocsLive.handle_event("paper-ops", params, denied_socket)

      assert denied_again_socket.assigns.last_save_ok? == false
      assert stored_blocks(slug) == committed_blocks
    end

    test "canvas readiness refresh pushes the shared display channels", %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      assert_push_event(view, "bp:task-preview", %{previews: []})
      assert_push_event(view, "bp:block-html", %{renders: []})

      render_hook(view, "task-preview-refresh", %{})
      assert_push_event(view, "bp:task-preview", %{previews: []})
      assert_push_event(view, "bp:block-html", %{renders: []})
    end

    test "slash insertion and ghost materialization persist through reader canvas events", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      render_hook(view, "paper-slash-insert", %{
        "type" => "heading",
        "afterId" => "b-body"
      })

      blocks = stored_blocks(slug)
      body_index = Enum.find_index(blocks, &(&1["id"] == "b-body"))
      inserted = Enum.at(blocks, body_index + 1)
      assert inserted["type"] == "heading"
      assert String.starts_with?(inserted["id"], "b-")

      render_hook(view, "paper-materialize-slot", %{
        "kind" => "ingress",
        "after" => "b-head"
      })

      materialized =
        slug
        |> stored_blocks()
        |> Enum.find(&(&1["role"] == "ingress"))

      assert materialized["type"] == "paragraph"
      assert materialized["content"] == []
      assert assigns_of(view).save_status == "Auto-saved"
    end

    test "paper-add-block then paper-delete-block round-trips", %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      before_ids = Enum.map(stored_blocks(slug), & &1["id"])

      render_hook(view, "paper-add-block", %{"block-type" => "paragraph"})

      after_ids = Enum.map(stored_blocks(slug), & &1["id"])
      assert length(after_ids) == length(before_ids) + 1

      [new_id] = after_ids -- before_ids
      assert Enum.map(assigns_of(view).edit_blocks, & &1["id"]) == after_ids

      render_hook(view, "paper-delete-block", %{"id" => new_id})

      assert Enum.map(stored_blocks(slug), & &1["id"]) == before_ids
      assert Enum.map(assigns_of(view).edit_blocks, & &1["id"]) == before_ids
      refute flash_of(view)["error"]
    end

    test "paper-move-block reorders through the same move-block op", %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      render_hook(view, "paper-move-block", %{"id" => "b-extra", "dir" => "up"})

      assert Enum.map(stored_blocks(slug), & &1["id"]) == ["b-head", "b-extra", "b-body"]
      assert Enum.map(assigns_of(view).edit_blocks, & &1["id"]) == ["b-head", "b-extra", "b-body"]
    end

    test "a rejected canvas save reports failure and the server keeps edit mode open", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => "missing-block",
        "patch" => %{"text" => "must not land"}
      })

      assert assigns_of(view).last_save_ok? == false
      assert assigns_of(view).save_status == "Save failed"

      still_editing = render_click(view, "paper-toggle-edit", %{})
      assert assigns_of(view).editing? == true
      assert still_editing =~ ~s(data-test-id="studio-paper-block-editor")

      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-body",
        "patch" => %{"content" => [%{"type" => "text", "value" => "Recovered"}]}
      })

      assert assigns_of(view).last_save_ok? == true
      assert assigns_of(view).save_status == "Auto-saved"

      viewing = render_click(view, "paper-toggle-edit", %{})
      assert assigns_of(view).editing? == false
      assert viewing =~ "Recovered"
    end

    test "nested PaperFieldBlock messages persist through the reader parent", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(writer_conn(conn), "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      send(view.pid, {
        :paper_op,
        %{
          "op" => "patch-block",
          "id" => "b-body",
          "patch" => %{"content" => [%{"type" => "text", "value" => "Nested saved"}]}
        }
      })

      render(view)
      assert block_text(slug, "b-body") == "Nested saved"
      assert assigns_of(view).last_save_ok? == true
      assert assigns_of(view).save_status == "Auto-saved"
    end
  end

  describe "criterion 3 — the View HTML is untouched when not editing" do
    test "a writer who never toggles renders the same article an anonymous reader does", %{
      conn: conn,
      slug: slug
    } do
      {:ok, _anon, anon_html} = live(scoped_conn(), "/papers/#{slug}")
      {:ok, _writer, writer_html} = live(writer_conn(conn), "/papers/#{slug}")

      # The ONLY difference is the edit bar; the article body is byte-identical.
      assert anon_article(anon_html) == anon_article(writer_html)
      refute anon_html =~ "paper-edit-bar"
      assert writer_html =~ "paper-edit-bar"
    end
  end

  # The Edit/View toggle's visible label.
  defp toggle_label(html) do
    case Regex.run(~r/id="paper-edit-toggle"[^>]*>(.*?)<\/button>/s, html) do
      [_, label] -> String.trim(label)
      _ -> flunk("no #paper-edit-toggle in the render")
    end
  end

  # The <article id="paper-body" …> subtree — the View surface the parity
  # workflow audits. Compared verbatim across viewers.
  defp anon_article(html) do
    case Regex.run(~r/<article id="paper-body".*?<\/article>/s, html) do
      [article] -> article
      _ -> flunk("no #paper-body article in:\n#{html}")
    end
  end
end
