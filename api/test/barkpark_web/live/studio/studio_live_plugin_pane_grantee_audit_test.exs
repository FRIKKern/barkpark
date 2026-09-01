defmodule BarkparkWeb.Studio.StudioLivePluginPaneGranteeAuditTest do
  @moduledoc """
  Plugin-pane grantee audit (airdrop-grants · ag-plugin-pane-grantee-audit).

  ## VERDICT — NO LEAK (fail-closed by grant row-narrowing, not by absence)

  A grant-admitted, non-member Studio socket ({:grant, ctx} admission via
  `BarkparkWeb.LiveScope.authorize_read/4`, live_scope.ex:104-160) does NOT
  execute any UNNARROWED plugin-context read through the pane-load path. Traced
  end-to-end:

    * The desk is assembled by `StudioLive`'s `rebuild_panes/1`
      (studio_live/shared.ex:631-635), which threads
      `BarkparkWeb.ScopeHelpers.scope_opts(socket)` into
      `PaneBuilder.build(dataset, nav_path, scope: …)`.
    * For a grant socket `scope_opts/1` carries `grant_scoped: true` +
      the grant-bearing `caller_context` (scope_helpers.ex:72-81,
      set by `LiveScope.assign_grant_scope/2`, live_scope.ex:281-286).
    * `PaneBuilder`'s `scope(opts)` (pane_builder.ex:526-531) returns that
      whole keyword UNTOUCHED into EVERY content read it performs —
      `Content.list_documents` (pane_builder.ex:258, :310),
      `Content.get_paper` (:185), `Content.fetch_doc_with_draft`
      (:201, :335), `resolve_graph_doc` (:152).
    * Each of those routes through `Content.Query.base_query/4`
      (content/query.ex:Query.base_query/4) → `maybe_scope_to_grants/2`
      (content/scope.ex:Scope.maybe_scope_to_grants/2, imported by
      `Content.Query`) →
      `Content.Scope.scope_to_grants/3`, which restricts the read to the
      caller's grant ladder and FAILS CLOSED (`where: false`) for any type/
      doc/project/dataset OUTSIDE the grant. Both perspectives
      (`:raw` and `:drafts`) share `base_query`, so both narrow.
    * The ONLY `Barkpark.Plugins.*` calls in the pane path are
      `Plugins.Registry.collect_desk_items_attributed/1` and
      `Registry.all/0` (structure.ex:210, :354) — they enumerate the
      plugin-DECLARED desk NAV items + owned-type map (schema chrome), never
      document CONTENT. NO plugin CONTEXT (Barkpark.Tasks / Media / Sheets /
      Tickets / Quiz) is invoked for content on the pane-load path.

  So there is no leak to gate: the pane path narrows plugin-type document reads
  through the SAME `grant_scoped` seam as ordinary document reads (proven at the
  socket level in `ScopedStudioMountTest` "OBSERVABLE NARROWING"). This test
  therefore PINS that fail-closed behavior at the RENDERED-DESK layer — the one
  layer that test did not cover — so a future refactor that drops `scope(opts)`
  from a plugin-content read (or adds a direct plugin-context read to the pane
  path) reds this guard.

  ## What is proven here

  A grantee holding a TYPE-scoped grant (`type: "post"`) in workspace A mounts
  the DESK for out-of-grant plugin-content types ("task", "sheet" — both are
  Content-document-backed plugin families; the `scope_to_grants` seam is
  type-agnostic, so these stand in for the whole task/sheet/media/tickets/quiz
  family). The desk NEVER serves that out-of-grant plugin content. A real
  MEMBER of workspace A mounting the SAME desk DOES see it — the positive
  control that makes the grantee's empty pane ENFORCEMENT, not an empty DB
  (distrust-vacuous-green: a deny test whose content isn't proven renderable is
  half a test).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Access.Grant
  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  # A granted type + two OUT-of-grant plugin-content types. Both "task" and
  # "sheet" are Content-document-backed plugin families; the enforcement seam
  # (`scope_to_grants`) is type-agnostic, so they represent the whole
  # task/sheet/media/tickets/quiz plugin family.
  @granted_type "post"
  @plugin_types ~w(task sheet)

  @in_grant_title "IN-GRANT-POST-VISIBLE"
  @secret_task_title "SECRET-TASK-CONTENT-OUT-OF-GRANT"
  @secret_sheet_title "SECRET-SHEET-CONTENT-OUT-OF-GRANT"

  setup %{conn: conn} do
    ws_a = create_workspace!("plugin-pane-a")
    proj_a = create_project!(ws_a, "plugin-pane-pa")

    # Register the granted type + the plugin-content types IN workspace A so the
    # scoped desk surfaces them (a Default-stamped schema is invisible to A's
    # scoped desk — mirrors StudioLiveDeskScopeLeakTest).
    for {name, title} <- [
          {@granted_type, "Post"},
          {"task", "Task"},
          {"sheet", "Sheet"}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => title,
            "icon" => "file-text",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )
    end

    # In-grant + out-of-grant content, ALL in ws_a/proj_a/@dataset — isolation
    # here must come from the GRANT ladder (type), not tenancy or dataset.
    {:ok, _} = create_doc(ws_a, proj_a, @granted_type, @in_grant_title)
    {:ok, _} = create_doc(ws_a, proj_a, "task", @secret_task_title)
    {:ok, _} = create_doc(ws_a, proj_a, "sheet", @secret_sheet_title)

    # A real MEMBER of ws_a — the positive control that the plugin content is
    # genuinely present and pane-renderable.
    member_conn = member_session(conn, ws_a)

    {:ok, conn: conn, member_conn: member_conn, ws_a: ws_a, proj_a: proj_a}
  end

  describe "grant-admitted socket · plugin-pane read narrowing" do
    test "DENY — a type-scoped grantee's desk never serves out-of-grant plugin content", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {user, conn} = grantee_session(conn)

      # Grant is TYPE-scoped to "post": admission validates the mounted desk
      # scope (ws_a, proj_a, dataset) — type is below desk granularity, so the
      # grantee is ADMITTED to the plugin desks, then NARROWED at read time.
      bind_grant!(ws_a, user, %{
        project_id: proj_a.id,
        dataset: @dataset,
        type: @granted_type,
        capabilities: ["read"]
      })

      for plugin_type <- @plugin_types do
        {:ok, view, html} = live(conn, plugin_desk_url(ws_a, proj_a, plugin_type))

        socket = :sys.get_state(view.pid).socket

        # Sanity: we ARE on the grant-narrowing path (not an accidental
        # member/anonymous mount that would make the empty pane meaningless).
        assert socket.assigns.grant_scoped_read == true,
               "expected the grant read-narrowing seam on the socket for #{plugin_type}"

        assert %CallerContext{grants: [%Grant{}]} = socket.assigns.caller_context

        titles = desk_doc_titles(socket)

        refute @secret_task_title in titles,
               "PLUGIN-PANE GRANT LEAK: out-of-grant task content reached the grantee's " <>
                 "#{plugin_type} desk (got #{inspect(titles)})"

        refute @secret_sheet_title in titles,
               "PLUGIN-PANE GRANT LEAK: out-of-grant sheet content reached the grantee's " <>
                 "#{plugin_type} desk (got #{inspect(titles)})"

        # HTML layer — what the browser actually paints.
        refute html =~ @secret_task_title
        refute html =~ @secret_sheet_title
      end
    end

    test "POSITIVE CONTROL — a real member's desk DOES serve the same plugin content", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      # Same URLs, an unnarrowed member: the content is real and the pane
      # renders it, so the grantee's empty pane above is ENFORCEMENT, not vacuum.
      {:ok, task_view, task_html} = live(conn, plugin_desk_url(ws_a, proj_a, "task"))
      task_titles = desk_doc_titles(:sys.get_state(task_view.pid).socket)

      assert @secret_task_title in task_titles,
             "positive control failed: member desk did not list the task content " <>
               "(got #{inspect(task_titles)}) — the deny test would be vacuous"

      assert task_html =~ @secret_task_title

      {:ok, sheet_view, _} = live(conn, plugin_desk_url(ws_a, proj_a, "sheet"))
      sheet_titles = desk_doc_titles(:sys.get_state(sheet_view.pid).socket)

      assert @secret_sheet_title in sheet_titles,
             "positive control failed: member desk did not list the sheet content " <>
               "(got #{inspect(sheet_titles)})"
    end

    test "GRANTEE DESK IS LIVE — the same grantee still sees its IN-grant content", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      # Proves the grantee's empty plugin panes are SELECTIVE narrowing, not a
      # globally dead desk: the granted "post" type surfaces the in-grant doc.
      {user, conn} = grantee_session(conn)

      bind_grant!(ws_a, user, %{
        project_id: proj_a.id,
        dataset: @dataset,
        type: @granted_type,
        capabilities: ["read"]
      })

      {:ok, view, html} = live(conn, plugin_desk_url(ws_a, proj_a, @granted_type))
      titles = desk_doc_titles(:sys.get_state(view.pid).socket)

      assert @in_grant_title in titles,
             "the grantee desk should list its in-grant post (got #{inspect(titles)})"

      assert html =~ @in_grant_title
      # And even on its GRANTED desk it never leaks the sibling plugin content.
      refute @secret_task_title in titles
      refute @secret_sheet_title in titles
    end
  end

  # ── helpers (local per slice charter — fixture consolidation is owned by
  #    ag-deny-matrix-gaps; these mirror ScopedStudioMountTest) ───────────────

  defp plugin_desk_url(ws, proj, type),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}"

  # Every :doc row across every rendered pane — the authoritative "what the desk
  # serves" set (mirrors StudioLiveDeskScopeLeakTest).
  defp desk_doc_titles(socket) do
    socket.assigns.panes
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(Map.get(&1, :type) == :doc))
    |> Enum.map(& &1.title)
  end

  defp create_doc(ws, proj, type, title) do
    attrs =
      %{"_id" => "#{type}-#{System.unique_integer([:positive])}", "title" => title}
      # The tasks plugin enforces a task-content contract (kind + lifecycle_status);
      # every other type is a plain document. Supplying it keeps "task" a REAL
      # plugin type rather than a stand-in.
      |> maybe_task_fields(type)

    Content.create_document(type, attrs, @dataset, workspace_id: ws.id, project_id: proj.id)
  end

  defp maybe_task_fields(attrs, "task"),
    do: Map.merge(attrs, %{"kind" => "task", "lifecycle_status" => "open"})

  defp maybe_task_fields(attrs, _type), do: attrs

  defp grantee_session(conn) do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp member_session(conn, ws) do
    raw = "plugin-pane-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "plugin-pane-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp bind_grant!(ws, user, overrides) do
    attrs =
      %{
        grantor_id: grant_authority!(ws).id,
        grantee_email: user.email,
        grantee_user_id: user.id,
        claimed_at: DateTime.utc_now(),
        workspace_id: ws.id,
        capabilities: ["read"],
        link_token_hash: "hash-" <> Ecto.UUID.generate()
      }
      |> Map.merge(overrides)

    {:ok, grant} = %Grant{} |> Grant.changeset(attrs) |> Repo.insert()
    grant
  end

  defp grant_authority!(ws) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("ag-grantor-" <> Ecto.UUID.generate()),
        label: "ag-grantor",
        dataset: @dataset,
        permissions: ["read", "write", "admin"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "admin")
    token
  end
end
