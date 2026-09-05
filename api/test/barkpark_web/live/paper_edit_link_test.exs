defmodule BarkparkWeb.Live.PaperEditLinkTest do
  @moduledoc """
  Edit-on-the-link slice 3 (task-8ac4f3918da1c433, epic task-a19eeb215f653529):
  a PER-PAPER share link minted with `access: "edit"` opens the reader's own
  block editor for the ONE paper it binds, and opens nothing else anywhere.

  ## What the grant is

  `Barkpark.Sharing.Links` already validated `~w(read edit)` and
  `ShareLinkController.mint/2` already accepted `"edit"`; what did not exist
  was any surface that HONOURED it. Three seams carry the level now:

    * `RequireShareScope.maybe_grant_item_token/4` assigns `share_access:` from
      the LINK instead of a hard-coded `:read` (the safe-method guard is
      unchanged — an item link never grants an unsafe HTTP method);
    * `PluginScopeSession.build/1` records it in the SIGNED session as
      `"scoped_share_access"`;
    * `PaperViewer.viewer/3` puts the LIVE row's access + bound `ref_id` on
      `@viewer`, and `PaperViewer.can_edit?/3` grants exactly one extra way:
      access `:edit` AND `ref_id == slug` AND the link's workspace is the
      paper's.

  ## What the grant is NOT (the inertness half)

  The June ruling: a share credential never carries write/admin and never gets
  a membership row, because the flat `POST /v1/data/mutate/:dataset` authorizes
  on write-permission alone. An item edit link is just as inert — it is not an
  api token at all, so the flat and the scoped mutate routes reject its raw
  token outright, and it is confined to one slug at BOTH the dead render and
  the socket re-mount. Proved below rather than asserted.

  `async: false` — the `:shares` registry is process-global application env and
  one case plants a section share.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Content}
  alias Barkpark.Sharing.Links
  alias BarkparkWeb.BulldocsLive.Edit
  alias BarkparkWeb.PluginScopeSession

  @dataset "production"
  @granted_body "EDIT-LINK-GRANTED-BODY"
  @sibling_body "EDIT-LINK-SIBLING-BODY"
  @liveness_msg {BarkparkWeb.PluginScopeSession, :share_liveness_check}

  # The browser half the reader layout loads ONLY for a viewer who may edit
  # (`bulldocs.html.heex`, all `:if={assigns[:can_edit?]}`). Asserted on the
  # LIVE page here, not on the layout function, so the gate is proved end to
  # end for a share-link viewer.
  @editor_assets [
    ~s(href="/assets/bp-paper-editor-shell.css"),
    ~s(src="/assets/bp-paper-editor.bundle.js"),
    ~s(src="/assets/bp-paper-editor-hooks.js")
  ]

  # Every MVP editor event the reader wires, with a payload that WOULD write if
  # it reached a handler.
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
    Barkpark.SharingFixtures.snapshot_shares!()

    # A NON-default workspace: the seeded Default is an open public demo in
    # test, which would grant these reads for the wrong reason.
    ws = create_workspace!("edit-link-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws)

    granted = "edit-link-granted-#{System.unique_integer([:positive])}"
    sibling = "edit-link-sibling-#{System.unique_integer([:positive])}"

    seed_paper!(ws, proj, granted, @granted_body)
    seed_paper!(ws, proj, sibling, @sibling_body)

    %{conn: conn, ws: ws, proj: proj, granted: granted, sibling: sibling}
  end

  # A BLOCK paper (not body_html): the editor edits blocks. Three blocks so a
  # delete never trips the hollow-result ratchet.
  defp seed_paper!(ws, proj, slug, body) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Edit link probe #{slug}",
          "blocks" => [
            %{"id" => "b-head", "type" => "heading", "text" => "Edit link probe", "level" => 1},
            %{
              "id" => "b-body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => body}]
            },
            %{
              "id" => "b-extra",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Spare block"}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    paper
  end

  defp seed_picker_paper!(ws, proj, slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Picker confinement probe",
          "blocks" => [
            %{"id" => "b-head", "type" => "heading", "text" => "Picker probe", "level" => 1},
            %{
              "id" => "b-reference",
              "type" => "field-reference",
              "label" => "Related paper",
              "refType" => "paper",
              "value" => "already-visible-paper"
            },
            %{
              "id" => "b-image",
              "type" => "image",
              "src" => "https://example.invalid/already-visible.png",
              "alt" => "Already visible"
            },
            %{
              "id" => "b-extra",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Spare block"}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    paper
  end

  defp mint_link!(ws, proj, ref_id, access) do
    {:ok, {raw, link}} =
      Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        kind: "doc",
        ref_type: "paper",
        ref_id: ref_id,
        access: access
      })

    {raw, link}
  end

  defp as_nonmember(conn) do
    email = "edit-link-viewer-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp paper_path(ws, proj, slug), do: "/w/#{ws.slug}/p/#{proj.slug}/papers/#{slug}"

  defp shared_path(ws, proj, slug, raw), do: paper_path(ws, proj, slug) <> "?share=#{raw}"

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp flash_of(view), do: assigns_of(view).flash || %{}

  defp stored_blocks(slug, ws, proj) do
    case Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: proj.id) do
      %{content: %{"blocks" => blocks}} -> blocks
      _ -> nil
    end
  end

  defp block_text(slug, id, ws, proj) do
    slug
    |> stored_blocks(ws, proj)
    |> List.wrap()
    |> Enum.find(&(Map.get(&1, "id") == id))
    |> case do
      %{"content" => [%{"value" => value} | _]} -> value
      other -> other
    end
  end

  # THE ATTACK PRIMITIVE, lifted verbatim from
  # `share_link_live_remount_confinement_test.exs`: dead-render the granted
  # path (the page carries A's SIGNED LiveView session), then connect the
  # socket with the request path rewritten to the target. No plug runs on that
  # join — which is exactly what a `live_redirect` or a reconnect does.
  defp reproduce_socket_remount(conn, {granted_path, target_path}) do
    dead = get(conn, granted_path)

    assert dead.status == 200,
           "the granted dead render must succeed for the substitution to mean anything"

    live(%{dead | request_path: target_path, query_string: ""})
  end

  describe "criterion 1a — an edit link edits the paper it binds" do
    test "mounts as a :share viewer with access :edit and can_edit? true", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, link} = mint_link!(ws, proj, granted, "edit")

      {:ok, view, html} = live(conn, shared_path(ws, proj, granted, raw))

      assert html =~ @granted_body

      assigns = assigns_of(view)

      assert assigns.viewer == %{
               kind: :share,
               grant: :item,
               id: link.id,
               access: :edit,
               ref_id: granted,
               workspace_id: ws.id
             }

      assert assigns.can_edit? == true
      # No credential of any kind was presented — the LINK is the whole grant.
      assert assigns.current_user == nil
      assert assigns.api_token == nil

      # And the edit affordance is actually painted.
      assert html =~ ~s(id="paper-edit-toggle")
    end

    test "a logged-in nonmember keeps user attribution and may edit through the link", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      seed_picker_paper!(ws, proj, granted)
      {raw, link} = mint_link!(ws, proj, granted, "edit")
      {user, conn} = as_nonmember(conn)

      {:ok, view, html} = live(conn, shared_path(ws, proj, granted, raw))
      assigns = assigns_of(view)

      assert %{kind: :user, id: user_id} = assigns.viewer
      assert user_id == user.id
      assert assigns.current_user.id == user.id
      assert assigns.paper_share_grant.id == link.id
      assert assigns.paper_share_grant.access == :edit
      assert assigns.can_edit? == true
      assert assigns.picker_browse? == false
      assert html =~ ~s(id="paper-edit-toggle")

      editing = render_click(view, "paper-toggle-edit", %{})
      assert editing =~ ~s(data-canvas-picker-browse="false")
      assert editing =~ ~s(data-canvas-scope-prefix="/w/#{ws.slug}/p/#{proj.slug}")
      assert editing =~ "already-visible-paper"
      assert editing =~ "https://example.invalid/already-visible.png"
      assert editing =~ ~s(data-test-id="paper-picker-current")
      refute editing =~ "<bp-reference-picker"
      refute editing =~ "<bp-media-picker"

      socket = :sys.get_state(view.pid).socket

      assert {:reply, %{results: []}, _socket} =
               BarkparkWeb.BulldocsLive.handle_event(
                 "paper-wikilink-search",
                 %{"query" => "another paper"},
                 socket
               )

      assert {:reply, %{results: []}, _socket} =
               BarkparkWeb.BulldocsLive.handle_event(
                 "paper-tag-search",
                 %{"query" => "private-tag"},
                 socket
               )
    end

    test "a paper-op through the reader's op path persists", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      {:ok, view, _html} = live(conn, shared_path(ws, proj, granted, raw))

      editing = render_click(view, "paper-toggle-edit", %{})
      assert editing =~ ~s(data-test-id="studio-paper-block-editor")
      assert assigns_of(view).editing? == true

      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-body",
        "patch" => %{"content" => [%{"type" => "text", "value" => "Edited over the link"}]}
      })

      assert block_text(granted, "b-body", ws, proj) == "Edited over the link"
      assert assigns_of(view).save_status == "Auto-saved"
      assert assigns_of(view).paper_halt == nil
      refute flash_of(view)["error"]
    end

    test "an edit-link batch replays once and revocation denies every subsequent retry", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, link} = mint_link!(ws, proj, granted, "edit")
      {:ok, view, _html} = live(conn, shared_path(ws, proj, granted, raw))
      render_click(view, "paper-toggle-edit", %{})
      request_id = Ecto.UUID.generate()

      params = %{
        "request_id" => request_id,
        "ops" => [
          %{
            "op" => "insert-after",
            "afterId" => "b-body",
            "block" => %{"id" => "shared-once", "type" => "paragraph", "text" => "Saved once"}
          }
        ]
      }

      render_hook(view, "paper-ops", params)
      assert assigns_of(view).last_save_ok? == true
      before = stored_blocks(granted, ws, proj)
      assert Enum.count(before, &(&1["id"] == "shared-once")) == 1
      socket = :sys.get_state(view.pid).socket

      assert {:reply, %{saved: true, request_id: ^request_id, replayed: true}, socket} =
               BarkparkWeb.BulldocsLive.handle_event("paper-ops", params, socket)

      assert stored_blocks(granted, ws, proj) == before
      {:ok, _} = Links.revoke(link.id)

      Enum.reduce(1..2, socket, fn _, previous ->
        assert {:reply, %{saved: false, request_id: ^request_id}, refused} =
                 BarkparkWeb.BulldocsLive.handle_event("paper-ops", params, previous)

        assert refused.assigns.last_save_ok? == false
        assert stored_blocks(granted, ws, proj) == before
        refused
      end)
    end

    test "the reader loads the editor assets for an edit-link viewer", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      {:ok, _view, html} = live(conn, shared_path(ws, proj, granted, raw))

      for tag <- @editor_assets do
        assert html =~ tag, "an edit-link reader page must load #{tag}"
      end
    end
  end

  describe "criterion 1b — a READ link is unchanged" do
    test "mounts with access :read, can_edit? false, and no editor assets", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, link} = mint_link!(ws, proj, granted, "read")

      {:ok, view, html} = live(conn, shared_path(ws, proj, granted, raw))

      assert html =~ @granted_body
      assert assigns_of(view).viewer.access == :read
      assert assigns_of(view).viewer.id == link.id
      assert assigns_of(view).can_edit? == false

      refute html =~ ~s(id="paper-edit-toggle")
      refute html =~ "studio-paper-block-editor"

      for tag <- @editor_assets do
        refute html =~ tag, "a read-link reader page must not load #{tag}"
      end
    end

    test "a logged-in nonmember remains read-only through a read link", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "read")
      {user, conn} = as_nonmember(conn)

      {:ok, view, html} = live(conn, shared_path(ws, proj, granted, raw))

      assert %{kind: :user, id: user_id} = assigns_of(view).viewer
      assert user_id == user.id
      assert assigns_of(view).paper_share_grant.access == :read
      assert assigns_of(view).can_edit? == false
      refute html =~ ~s(id="paper-edit-toggle")
    end

    test "every MVP paper-* event is refused server-side and writes nothing", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "read")

      {:ok, view, _html} = live(conn, shared_path(ws, proj, granted, raw))

      before = stored_blocks(granted, ws, proj)

      for {event, params} <- @denied_probes do
        params =
          if event == "paper-ops",
            do: Map.put(params, "request_id", Ecto.UUID.generate()),
            else: params

        render_hook(view, event, params)

        assert flash_of(view)["error"] == Edit.denial(), "#{event} was not refused"
        assert stored_blocks(granted, ws, proj) == before, "#{event} wrote to the paper"
      end

      assert assigns_of(view).editing? == false
    end

    test "the whole gated roster is refused for a read link", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "read")

      {:ok, view, _html} = live(conn, shared_path(ws, proj, granted, raw))

      for event <- Edit.edit_events() do
        render_hook(view, event, %{})
        assert flash_of(view)["error"] == Edit.denial(), "#{event} was not refused"
      end
    end
  end

  describe "criterion 1c — an edit link for A is refused on B" do
    test "the dead render for the sibling slug is 403", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted,
      sibling: sibling
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      conn = get(conn, shared_path(ws, proj, sibling, raw))
      assert conn.status == 403
    end

    test "a logged-in nonmember cannot use an edit link on a section-readable sibling", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted,
      sibling: sibling
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")
      {_user, conn} = as_nonmember(conn)
      Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")

      {:ok, view, html} = live(conn, shared_path(ws, proj, sibling, raw))

      assert html =~ @sibling_body
      assert assigns_of(view).viewer.kind == :user
      assert assigns_of(view).paper_share_grant.ref_id == granted
      assert assigns_of(view).can_edit? == false
      refute html =~ ~s(id="paper-edit-toggle")
    end

    test "the socket re-mount onto the sibling slug is halted", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted,
      sibling: sibling
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      result =
        reproduce_socket_remount(conn, {
          shared_path(ws, proj, granted, raw),
          paper_path(ws, proj, sibling)
        })

      # EVIDENCE ORDER: assert the READ did not happen first, so an unfixed
      # tree fails naming the leaked body rather than merely "not refused".
      refute leaked?(result, @sibling_body),
             "the socket re-mount RENDERED #{@sibling_body} — a paper the edit link never granted"

      assert {:error, {:redirect, %{to: "/login"}}} = result
    end

    test "positive control: the same substitution back onto A still mounts writable", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      assert {:ok, view, html} =
               reproduce_socket_remount(conn, {
                 shared_path(ws, proj, granted, raw),
                 paper_path(ws, proj, granted)
               })

      assert html =~ @granted_body
      assert assigns_of(view).can_edit? == true
    end
  end

  describe "criterion 1d — the raw link token is not a credential anywhere" do
    test "as a Bearer on the FLAT POST /v1/data/mutate/:dataset it is rejected", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/data/mutate/#{@dataset}", %{
          "type" => "paper",
          "id" => granted,
          "title" => "hijacked over the flat route"
        })

      assert resp.status in [401, 403],
             "the flat mutate route accepted an item share link (status #{resp.status})"

      # And nothing moved.
      assert block_text(granted, "b-body", ws, proj) == @granted_body
    end

    test "as a Bearer on the SCOPED mutate route it is rejected", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/data/mutate/#{@dataset}", %{
          "type" => "paper",
          "id" => granted,
          "title" => "hijacked over the scoped route"
        })

      assert resp.status in [401, 403],
             "the scoped mutate route accepted an item share link (status #{resp.status})"

      assert block_text(granted, "b-body", ws, proj) == @granted_body
    end

    test "the token in the ?share= query string does not open an unsafe method either", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/w/#{ws.slug}/p/#{proj.slug}/v1/data/mutate/#{@dataset}?share=#{raw}",
          %{"type" => "paper", "id" => granted, "title" => "hijacked over the share param"}
        )

      assert resp.status in [401, 403]
      assert block_text(granted, "b-body", ws, proj) == @granted_body
    end
  end

  describe "criterion 3 — revoking an edit link makes it read-only with no restart" do
    test "the already-open socket is torn down on the next liveness tick", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, link} = mint_link!(ws, proj, granted, "edit")

      {:ok, view, _html} = live(conn, shared_path(ws, proj, granted, raw))
      assert assigns_of(view).can_edit? == true

      {:ok, _} = Links.revoke(link.id)

      # The revoke call alone does not touch the open socket — the TICK does.
      # Asserting this first proves the teardown below is the liveness
      # mechanism and not some other side channel.
      assert Process.alive?(view.pid)

      send(view.pid, @liveness_msg)

      assert_redirect(view, "/login")
    end

    test "the NEXT mount over the revoked link is refused outright", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, link} = mint_link!(ws, proj, granted, "edit")

      dead = get(conn, shared_path(ws, proj, granted, raw))
      assert dead.status == 200

      {:ok, _} = Links.revoke(link.id)

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(%{dead | request_path: paper_path(ws, proj, granted), query_string: ""})

      # And the dead render is gone too, with no restart in between.
      assert get(conn, shared_path(ws, proj, granted, raw)).status == 403
    end

    test "on a section-shared scope the revoked edit link degrades to a READ-ONLY mount", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, link} = mint_link!(ws, proj, granted, "edit")

      # The section share is what keeps the reader mounting at all; the item
      # link was never what granted it. Without this arm a revoked link simply
      # denies, so this is the one shape where "read-only, not locked out" is
      # observable.
      Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")

      {:ok, view, _html} = live(conn, shared_path(ws, proj, granted, raw))
      assert assigns_of(view).can_edit? == true

      {:ok, _} = Links.revoke(link.id)

      {:ok, view2, html2} = live(conn, shared_path(ws, proj, granted, raw))

      assert html2 =~ @granted_body
      assert assigns_of(view2).viewer.grant == :section
      assert assigns_of(view2).viewer.access == :read
      assert assigns_of(view2).can_edit? == false

      before = stored_blocks(granted, ws, proj)

      render_hook(view2, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-body",
        "patch" => %{"content" => [%{"type" => "text", "value" => "written after revoke"}]}
      })

      assert flash_of(view2)["error"] == Edit.denial()
      assert stored_blocks(granted, ws, proj) == before
    end

    test "an open section-readable socket downgrades after revoke and refuses further edits", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, link} = mint_link!(ws, proj, granted, "edit")
      {user, conn} = as_nonmember(conn)
      Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")

      {:ok, view, _html} = live(conn, shared_path(ws, proj, granted, raw))
      assert assigns_of(view).can_edit? == true
      assert assigns_of(view).viewer.id == user.id

      assert render_click(view, "paper-toggle-edit", %{}) =~
               ~s(data-test-id="studio-paper-block-editor")

      assert assigns_of(view).editing? == true

      {:ok, _} = Links.revoke(link.id)
      send(view.pid, @liveness_msg)

      assigns = assigns_of(view)
      assert Process.alive?(view.pid)
      assert %{kind: :user, id: user_id} = assigns.viewer
      assert user_id == user.id
      assert assigns.paper_share_grant.grant == :section
      assert assigns.can_edit? == false
      assert assigns.editing? == false

      reader_html = render(view)
      assert reader_html =~ @granted_body
      refute reader_html =~ ~s(data-test-id="studio-paper-block-editor")
      refute reader_html =~ ~s(id="paper-edit-toggle")

      before = stored_blocks(granted, ws, proj)

      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-body",
        "patch" => %{"content" => [%{"type" => "text", "value" => "stale write"}]}
      })

      assert flash_of(view)["error"] == Edit.denial()
      assert stored_blocks(granted, ws, proj) == before
    end
  end

  describe "the session contract carries the access level" do
    test "build/1 records scoped_share_access for both levels", %{
      conn: conn,
      ws: ws,
      proj: proj,
      granted: granted
    } do
      for {access, expected} <- [{"edit", "edit"}, {"read", "read"}] do
        {raw, _link} = mint_link!(ws, proj, granted, access)

        dead = get(conn, shared_path(ws, proj, granted, raw))
        assert dead.status == 200

        session = PluginScopeSession.build(dead)

        assert session["scoped_share_public"] == true
        assert session["scoped_share_token"] == raw
        assert session["scoped_share_access"] == expected
      end
    end

    test "a session claiming edit for a READ link still grades read-only", %{
      ws: ws,
      proj: proj,
      granted: granted
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "read")

      # The intersection is the point: the session is signed, but the LIVE row
      # is the other half of the AND, so a forged/stale "edit" claim cannot
      # promote a read link.
      session = %{
        "scoped_share_public" => true,
        "scoped_share_token" => raw,
        "scoped_share_access" => "edit"
      }

      viewer = BarkparkWeb.PaperViewer.viewer(nil, nil, session)
      grant = BarkparkWeb.PaperViewer.resolve_share_grant(session)

      assigns = %{
        viewer: viewer,
        paper_share_grant: grant,
        current_project: %{id: proj.id},
        dataset: @dataset
      }

      assert viewer.access == :read
      assert BarkparkWeb.PaperViewer.can_edit?(assigns, ws.id, granted) == false
    end

    test "an edit link never grades writable for a DIFFERENT slug or workspace", %{
      ws: ws,
      proj: proj,
      granted: granted,
      sibling: sibling
    } do
      {raw, _link} = mint_link!(ws, proj, granted, "edit")

      session = %{
        "scoped_share_public" => true,
        "scoped_share_token" => raw,
        "scoped_share_access" => "edit"
      }

      viewer = BarkparkWeb.PaperViewer.viewer(nil, nil, session)
      grant = BarkparkWeb.PaperViewer.resolve_share_grant(session)

      assigns = %{
        viewer: viewer,
        paper_share_grant: grant,
        current_project: %{id: proj.id},
        dataset: @dataset
      }

      assert viewer.access == :edit
      assert BarkparkWeb.PaperViewer.can_edit?(assigns, ws.id, granted) == true

      # Same workspace, sibling slug.
      assert BarkparkWeb.PaperViewer.can_edit?(assigns, ws.id, sibling) == false
      # Bound slug, foreign workspace.
      assert BarkparkWeb.PaperViewer.can_edit?(assigns, Ecto.UUID.generate(), granted) ==
               false

      # Matching workspace/slug but a foreign project or dataset is still out of scope.
      assert BarkparkWeb.PaperViewer.can_edit?(
               %{assigns | current_project: %{id: Ecto.UUID.generate()}},
               ws.id,
               granted
             ) == false

      assert BarkparkWeb.PaperViewer.can_edit?(
               %{assigns | dataset: "staging"},
               ws.id,
               granted
             ) == false

      # And the 2-arity — which knows no slug — is false for every share viewer.
      assert BarkparkWeb.PaperViewer.can_edit?(%{viewer: viewer}, ws.id) == false
    end
  end

  # Same helper the sibling confinement test uses: a mount result that RENDERED
  # the needle, whichever shape the LiveView test returned.
  defp leaked?({:ok, view, needle_html}, needle),
    do: needle_html =~ needle or render(view) =~ needle

  defp leaked?(_result, _needle), do: false
end
