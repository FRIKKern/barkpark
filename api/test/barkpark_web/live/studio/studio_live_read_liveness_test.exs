defmodule BarkparkWeb.Studio.StudioLiveReadLivenessTest do
  @moduledoc """
  ag-liveview-read-liveness — an expired or revoked grant stops serving rows on a
  LIVE Studio socket, not just on reconnect.

  Ground truth before this slice: WRITES were already closed (the Caps gate
  re-derives per mutating event), but READS leaked. The row-narrowing
  `Content.Scope.scope_to_grants` reads `caller_context.grants`, which
  `ScopeHelpers.scope_opts(socket)` pulls verbatim from the MOUNT-TIME
  `:caller_context` assign — so a grantee sitting in a mounted desk kept reading
  granted rows after expiry AND after revoke until reconnect.

  These tests prove the DENY paths NON-VACUOUSLY on a live socket:

    * expiry → the `:access_expiry_tick` refresh rebuilds `caller_context` and,
      when the desk's only covering grant is gone, KILLS the socket (redirect);
    * revoke → `Access.revoke/2` broadcasts `{:airdrop_revoked}` and the mounted
      socket refreshes + re-runs admission, killing an uncovered desk;
    * the caller_context rebuild NARROWS the grant snapshot live while admission
      STILL holds (a second valid grant) — no over-deny;
    * positive control — a still-valid grant keeps serving its rows across a tick.

  The mount-time snapshot leak that these guard is why the whole slice exists:
  each DENY test is RED on the pre-fix code (the tick refreshed only caps, the
  revoke emitted audit only). Local grant helpers only — the caps-gate /
  scoped-mount helpers are owned by ag-deny-matrix-gaps.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Access
  alias Barkpark.Access.Grant
  alias Barkpark.Accounts
  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "production"

  setup %{conn: conn} do
    # A PRIVATE workspace: the Default workspace is an open public-demo in test
    # (`public_demo_studio: true`), so a grantee there mounts as the anonymous
    # grade (no grant narrowing). A private workspace exercises the real grant
    # grade + the row-narrowing read path this slice hardens.
    priv_ws = create_workspace!("live-priv-#{System.unique_integer([:positive])}")
    priv_proj = create_project!(priv_ws, "live-priv-proj")

    # arpss-w8: refresh-proof Default-OFF baseline. A bare `put_env(:shares, [])`
    # is undone by the next Sharing.refresh/0 (which this suite CAN reach through
    # the forged `shares-add` events), and it never snapshots :shares_env.
    Barkpark.SharingFixtures.clear_shares!()

    {:ok, conn: conn, ws: priv_ws, proj: priv_proj}
  end

  defp desk_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  # A signed-in, non-member USER — admitted only by a covering grant.
  defp grantee_session(conn) do
    email = "live-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # A LIVE grantor (finding ag-1): an admin member of `ws` holding read+write+
  # admin, so a grant it mints still confers AND it may revoke that grant.
  defp grant_authority!(ws) do
    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token("ag-grantor-" <> Ecto.UUID.generate()),
        label: "ag-grantor",
        dataset: "test",
        permissions: ["read", "write", "admin"]
      })
      |> Repo.insert()

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, token.id, "admin")
    token
  end

  # Insert a grant bound (claimed) to `user`, minted by `grantor`.
  defp bind_grant!(ws, user, grantor, overrides) do
    attrs =
      %{
        grantor_id: grantor.id,
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

  # Force a grant's expiry into the past IN THE DB (mirrors a grant crossing its
  # expiry mid-session), bypassing changeset validation.
  defp expire_in_db!(%Grant{} = grant) do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    {:ok, _} = grant |> Ecto.Changeset.change(expires_at: past) |> Repo.update()
    :ok
  end

  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp caller_grants(view) do
    :sys.get_state(view.pid).socket.assigns.caller_context.grants
  end

  # ── 1. expiry → dead desk (criterion 1) ─────────────────────────────────────

  describe "expiry stops serving on a LIVE socket" do
    test "a grantee whose ONLY grant expires mid-session is killed by the tick", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {user, conn} = grantee_session(conn)
      grantor = grant_authority!(ws)
      # Expires in the future so the mount admits and no auto-tick fires yet.
      grant = bind_grant!(ws, user, grantor, %{capabilities: ["read"], expires_at: future(3600)})

      {:ok, view, _html} = live(conn, desk_url(ws, proj))
      # Baseline: the desk mounted, grant-scoped, with the live grant in ctx.
      assert [%Grant{}] = caller_grants(view)

      # The grant crosses its expiry, then the reaper tick fires.
      expire_in_db!(grant)
      send(view.pid, :access_expiry_tick)

      # Dead desk = zero rows served — indistinguishable from no grant.
      assert_redirect(view, "/login")
    end
  end

  # ── 2. revoke → dead desk + broadcast (criteria 2 + 4) ──────────────────────

  describe "revoke stops serving on a LIVE socket" do
    test "Access.revoke mid-session broadcasts and kills the mounted desk", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {user, conn} = grantee_session(conn)
      grantor = grant_authority!(ws)
      grant = bind_grant!(ws, user, grantor, %{capabilities: ["read"]})

      {:ok, view, _html} = live(conn, desk_url(ws, proj))
      assert [%Grant{}] = caller_grants(view)

      # Server-side revoke by the grantor — emits the {:airdrop_revoked} push on
      # the grantee's user topic, which the mounted socket is subscribed to.
      assert {:ok, _revoked} = Access.revoke(grant.id, grantor)

      assert_redirect(view, "/login")
    end
  end

  # ── 3. caller_context rebuilt live, admission still holds (criteria 3 + 6) ───

  describe "the tick rebuilds caller_context (no over-deny)" do
    test "an expired grant drops from the live snapshot while a second grant keeps the desk",
         %{conn: conn, ws: ws, proj: proj} do
      {user, conn} = grantee_session(conn)
      grantor = grant_authority!(ws)
      # TWO workspace-wide read grants: one will expire, the other keeps the desk
      # admitted — so the tick narrows the snapshot without killing the socket.
      keep = bind_grant!(ws, user, grantor, %{capabilities: ["read"], expires_at: future(7200)})

      expiring =
        bind_grant!(ws, user, grantor, %{capabilities: ["read"], expires_at: future(3600)})

      {:ok, view, _html} = live(conn, desk_url(ws, proj))

      # Mount snapshot carries BOTH active grants.
      before_ids = caller_grants(view) |> Enum.map(& &1.id) |> Enum.sort()
      assert before_ids == Enum.sort([keep.id, expiring.id])

      # One grant crosses its expiry; the tick refreshes.
      expire_in_db!(expiring)
      send(view.pid, :access_expiry_tick)
      # Sync: render drains the mailbox (the tick is processed before it returns).
      assert is_binary(render(view))

      # The rebuilt caller_context dropped ONLY the expired grant — the live read
      # path now narrows to `keep`. Pre-fix the tick left the snapshot untouched.
      assert caller_grants(view) |> Enum.map(& &1.id) == [keep.id]

      # No over-deny: the socket is ALIVE (admission still holds via `keep`).
      assert Process.alive?(view.pid)
    end

    test "a still-valid grant keeps serving its rows across a tick (positive control)", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {user, conn} = grantee_session(conn)
      grantor = grant_authority!(ws)

      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Post",
            "icon" => "file-text",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      {:ok, _doc} =
        create_document_in!(ws, proj, "post", %{"title" => "GRANTED-DOC"}, @dataset)

      bind_grant!(ws, user, grantor, %{capabilities: ["read"], expires_at: future(7200)})

      {:ok, view, _html} =
        live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/post")

      assert desk_doc_titles(view) == ["GRANTED-DOC"]

      # A tick fires while the grant is STILL valid — nothing should change.
      send(view.pid, :access_expiry_tick)
      assert is_binary(render(view))

      assert Process.alive?(view.pid)
      assert [%Grant{}] = caller_grants(view)
      assert desk_doc_titles(view) == ["GRANTED-DOC"]
    end
  end

  defp desk_doc_titles(view) do
    :sys.get_state(view.pid).socket.assigns.panes
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(Map.get(&1, :type) == :doc))
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end
end
