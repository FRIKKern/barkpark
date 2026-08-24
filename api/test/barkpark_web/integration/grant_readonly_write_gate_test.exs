defmodule BarkparkWeb.Integration.GrantReadonlyWriteGateTest do
  @moduledoc """
  task-2b7cbaf8265f6b4e — a NON-MEMBER holding only a READ grant on a workspace
  must not complete a WRITE there.

  `BarkparkWeb.Plugs.RequireWritePermission.call/2` decided the write on
  `Tenancy.Auth.permits?(token, :write)` — a membership test on the token's own
  `permissions[]` array that takes no workspace argument and reads no grant —
  and RETURNED on success, so the workspace-aware `account_write?/1` arm below
  it was never reached. `ResolveWorkspace` admits a non-member user holding an
  ACTIVE `:read` grant (its grant arm), and admission there is read-only by
  construction. Nothing re-tested the grant for `:write`, so any write-capable
  token the caller held ANYWHERE completed the write — including
  `POST .../collections/:id/share`, which MINTS a public share token.

  Every request below goes over HTTP through the real endpoint + router, so the
  `:scoped_api`, `:media_mutate` and `:scoped_media_mutate` pipelines run
  exactly as in production.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Auth, Content, Tenancy}

  @password "correct-horse-battery"
  @ds "production"

  setup %{conn: conn} do
    ensure_default_scope!()

    # ── the VICTIM workspace: Alice is not a member of it ────────────────────
    ws_b = create_workspace!("victim-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "vp-#{System.unique_integer([:positive])}")
    col_id = "col-#{System.unique_integer([:positive])}"
    publish_collection!(col_id, "Victim campaign", ws_b, proj_b)

    # ── Alice: an ordinary signed-in user, NOT a member of workspace B ───────
    alice_email = "alice-#{System.unique_integer([:positive])}@example.com"
    {:ok, alice} = Accounts.register_user(%{email: alice_email, password: @password})
    {:ok, alice_session} = Accounts.create_user_session_token(alice)

    # ── Alice's OWN workspace, and a write-capable token bound to it ─────────
    # The ordinary state for any developer or mobile user of Barkpark: a
    # [read, write] token minted for the workspace they own (`create_token/5`
    # seats the token as a member of THAT workspace, and only that one). It
    # confers nothing in workspace B and is never presented as if it did.
    ws_a = create_workspace!("alice-#{System.unique_integer([:positive])}")
    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, alice.id, "admin", "user")
    alice_raw = "alice-write-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(alice_raw, "alice-app", @ds, ["read", "write"], ws_a.id)

    {:ok,
     conn: conn,
     ws_a: ws_a,
     ws_b: ws_b,
     proj_b: proj_b,
     col_id: col_id,
     alice: alice,
     alice_session: alice_session,
     alice_raw: alice_raw}
  end

  # A PUBLISHED mediaCollection stamped with `ws`/`proj`. `upsert_document`
  # always births a `drafts.` row, so the publish step is what makes the
  # collection resolvable through `Collections.get/3`.
  defp publish_collection!(col_id, title, ws, proj) do
    {:ok, _draft} =
      Content.upsert_document(
        "mediaCollection",
        %{
          "doc_id" => col_id,
          "title" => title,
          "content" => %{"kind" => "folder", "slug" => col_id}
        },
        @ds,
        source: :api,
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, doc} =
      Content.publish_document(col_id, "mediaCollection", @ds,
        workspace_id: ws.id,
        project_id: proj.id
      )

    doc
  end

  # The request as Alice can actually build it: her own write token as the
  # bearer, her own login session as the cookie, and `x-requested-with` so the
  # cookie arm of `:scoped_api` admits the session on a POST. Both credentials
  # are legitimately hers; neither says anything about workspace B.
  defp alice_conn(conn, %{alice_session: session, alice_raw: raw}) do
    conn
    |> Plug.Test.init_test_session(%{"user_session" => session})
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("x-requested-with", "XMLHttpRequest")
  end

  defp share_path(ws, proj, col_id),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/collections/#{col_id}/share"

  describe "a NON-MEMBER holding only a READ grant on workspace B" do
    test "is refused the collection share mint on B", ctx do
      %{ws_b: ws_b, proj_b: proj_b, col_id: col_id, alice: alice} = ctx

      # A read-only, workspace-scoped grant on B, claimed by Alice. The ordinary
      # airdrop shape: B's admin shares READ with an outsider.
      grant = bind_grant!(ws_b, alice, %{capabilities: ["read"]})
      assert grant.capabilities == ["read"]
      # The grant does NOT authorize :write — this is what the gate must honour.
      assert Tenancy.Auth.authorize(alice, ws_b.id, :write) == {:error, :forbidden}

      conn = ctx.conn |> alice_conn(ctx) |> post(share_path(ws_b, proj_b, col_id))

      assert conn.status == 403,
             "a READ-ONLY grantee minted a public share token on a workspace " <>
               "they are not a member of: #{conn.status} #{conn.resp_body}"

      # And no share token was actually minted on the victim's collection.
      {:ok, doc} =
        Content.get_document(col_id, "mediaCollection", @ds,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      refute get_in(doc.content, ["shareLink", "enabled"]) == true
    end

    test "is refused revoking a collection share on B", ctx do
      %{ws_b: ws_b, proj_b: proj_b, col_id: col_id, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn = ctx.conn |> alice_conn(ctx) |> delete(share_path(ws_b, proj_b, col_id))

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end

    test "is refused adding a member to a collection on B", ctx do
      %{ws_b: ws_b, proj_b: proj_b, col_id: col_id, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> post(
          "/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/media/#{@ds}/collections/#{col_id}/members",
          %{"assetId" => "no-such-asset"}
        )

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end

    test "is refused removing a member from a collection on B", ctx do
      %{ws_b: ws_b, proj_b: proj_b, col_id: col_id, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> delete(
          "/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/media/#{@ds}/collections/#{col_id}/members/no-such-asset"
        )

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end

    test "is refused the asset checkout lock on B", ctx do
      %{ws_b: ws_b, proj_b: proj_b, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> post("/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/media/#{@ds}/no-such-asset/checkout")

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end

    test "is refused the asset undo-checkout on B", ctx do
      %{ws_b: ws_b, proj_b: proj_b, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> post("/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/media/#{@ds}/no-such-asset/undo-checkout")

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end

    test "is refused the asset PATCH on B (:scoped_media_mutate)", ctx do
      %{ws_b: ws_b, proj_b: proj_b, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> patch("/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/media/#{@ds}/no-such-asset", %{
          "alt" => "pwned"
        })

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end

    test "is refused the asset DELETE on B (:scoped_media_mutate)", ctx do
      %{ws_b: ws_b, proj_b: proj_b, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> delete("/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/media/#{@ds}/no-such-asset")

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end
  end

  # The affected set is TEN routes, not the nine the finding named. Every scoped
  # write pipeline that (a) resolves a workspace from the URL through
  # `ResolveWorkspace` and (b) can carry a `:current_user` alongside an
  # `:api_token` is reachable by a grantee. That is `:scoped_api`, whose
  # `scoped_api_optional_credential` resolves the session cookie on a
  # state-changing method behind `x-requested-with`.
  describe "the tenth route the finding missed — scoped revision restore" do
    test "a READ-ONLY grantee is refused POST /v1/data/revision/:ds/:id/restore", ctx do
      %{ws_b: ws_b, proj_b: proj_b, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> post("/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/data/revision/#{@ds}/no-such-doc/restore")

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
    end
  end

  # The scoped document-mutate route is on `:scoped_mutate`, which resolves its
  # credential through `OptionalToken` — that plug assigns `:api_token` and
  # NEVER `:current_user`. `ResolveWorkspace`'s grant arm requires a non-nil
  # user (`not member? and not is_nil(user)`), so a grantee is never ADMITTED
  # there in the first place and is refused one gate earlier, by membership.
  # Pinned so a future cookie-aware rewrite of `:scoped_mutate` cannot open the
  # route silently: if this ever stops being 403 the grant arm became reachable.
  describe "the route that is NOT reachable, and why" do
    test "scoped /v1/data/mutate refuses the grantee at the MEMBERSHIP gate", ctx do
      %{ws_b: ws_b, proj_b: proj_b, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read"]})

      conn =
        ctx.conn
        |> alice_conn(ctx)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/data/mutate/#{@ds}",
          Jason.encode!(%{"mutations" => [%{"create" => %{"_id" => "x", "_type" => "post"}}]})
        )

      assert conn.status == 403, "expected 403 forbidden, got #{conn.status} #{conn.resp_body}"
      # The refusal names MEMBERSHIP, not the write tier — i.e. ResolveWorkspace
      # answered, not the write gate.
      assert conn.resp_body =~ "forbidden"
    end
  end

  describe "positive controls — the fix must not break legitimate writes" do
    test "a genuine MEMBER of B with a write token still mints the share", ctx do
      %{ws_b: ws_b, proj_b: proj_b, col_id: col_id} = ctx

      email = "bob-#{System.unique_integer([:positive])}@example.com"
      {:ok, bob} = Accounts.register_user(%{email: email, password: @password})
      {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, bob.id, "member", "user")
      {:ok, bob_session} = Accounts.create_user_session_token(bob)

      bob_raw = "bob-write-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(bob_raw, "bob-app", @ds, ["read", "write"], ws_b.id)

      conn =
        ctx.conn
        |> Plug.Test.init_test_session(%{"user_session" => bob_session})
        |> put_req_header("authorization", "Bearer " <> bob_raw)
        |> put_req_header("x-requested-with", "XMLHttpRequest")
        |> post(share_path(ws_b, proj_b, col_id))

      assert conn.status == 200,
             "a legitimate member was refused: #{conn.status} #{conn.resp_body}"

      assert %{"result" => %{"token" => t}} = json_response(conn, 200)
      assert is_binary(t)
    end

    test "a write-token holder in their OWN workspace still writes", ctx do
      %{ws_a: ws_a, alice_raw: alice_raw} = ctx

      proj_a = create_project!(ws_a, "ap-#{System.unique_integer([:positive])}")
      col_a = "cola-#{System.unique_integer([:positive])}"
      publish_collection!(col_a, "Alice's own", ws_a, proj_a)

      conn =
        ctx.conn
        |> Plug.Test.init_test_session(%{"user_session" => ctx.alice_session})
        |> put_req_header("authorization", "Bearer " <> alice_raw)
        |> put_req_header("x-requested-with", "XMLHttpRequest")
        |> post(share_path(ws_a, proj_a, col_a))

      assert conn.status == 200,
             "the token's own workspace was refused: #{conn.status} #{conn.resp_body}"
    end

    test "a bearer-only write token in its own workspace still writes (no session)", ctx do
      %{ws_a: ws_a, alice_raw: alice_raw} = ctx

      proj_a = create_project!(ws_a, "ap2-#{System.unique_integer([:positive])}")
      col_a = "colb-#{System.unique_integer([:positive])}"
      publish_collection!(col_a, "Alice's own, API client", ws_a, proj_a)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> alice_raw)
        |> post(share_path(ws_a, proj_a, col_a))

      assert conn.status == 200,
             "a bearer-only API client was refused in its own workspace: " <>
               "#{conn.status} #{conn.resp_body}"
    end

    test "a WRITE-capable grantee on B IS admitted (grants confer what they say)", ctx do
      # Not a membership control — a control on the FIX's shape: the remedy must
      # read the grant's capabilities, so a write grant still admits.
      %{ws_b: ws_b, proj_b: proj_b, col_id: col_id, alice: alice} = ctx
      bind_grant!(ws_b, alice, %{capabilities: ["read", "write"]})

      assert Tenancy.Auth.authorize(
               Barkpark.Content.CallerContext.from_user(alice.id),
               ws_b.id,
               :write
             ) == :ok

      conn = ctx.conn |> alice_conn(ctx) |> post(share_path(ws_b, proj_b, col_id))

      assert conn.status == 200,
             "a WRITE grantee was refused: #{conn.status} #{conn.resp_body}"
    end
  end
end
