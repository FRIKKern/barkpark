defmodule BarkparkWeb.Integration.ExportRevisionGrantNarrowingTest do
  @moduledoc """
  task-5fa8c834e1afa197 — the three token-required scoped reads that stream
  CONTENT rather than aggregates must honour the caller's grant ladder:

    * `GET /w/:ws/p/:proj/v1/data/export/:dataset`
    * `GET /w/:ws/p/:proj/v1/data/history/:dataset/:type/:doc_id`
    * `GET /w/:ws/p/:proj/v1/data/revision/:dataset/:id`

  `Content.Query.get_document/4` and (since task-59d79b4058a7a434) the three
  analytics aggregates thread `Content.Scope.maybe_scope_to_grants/2`.
  `Content.Export.export_stream/2`, `Content.Revisions.list_revisions/4` and
  `Content.Revisions.get_revision/3` did not — they scoped by dataset +
  `scope_to_workspace_or_global/3` and nothing else. Because
  `maybe_scope_to_grants/2` DEFAULTS its flag to false, the absent call meant
  "do not narrow", not "narrow to nothing": a grantee scoped to ONE type
  streamed the WHOLE dataset as full envelopes and read every revision of every
  document in it.

  The router comment at router.ex called this "a separate question (their query
  builders do not call `maybe_scope_to_grants/2` at all, so the pipeline alone
  would be inert there — a fix, not a move)". This suite is that fix's proof.

  REACHABILITY IS NOT ASSUMED. The first test in each grantee describe block is
  a precondition that asserts the door opens at all (200), so no refute below
  can pass vacuously on a 401/403/404. The drive is the one
  `analytics_grant_narrowing_test.exs` established and proved live: a grantee
  presents BOTH her own api token (minted into her OWN workspace — satisfies
  `RequireToken`, confers nothing in the victim workspace) and her login session
  cookie (`:scoped_api` resolves it on GET, so `ResolveWorkspace`'s grant arm's
  `not member? and not is_nil(user)` holds and `:grant_scoped_read` is set).

  THE MEMBER ARM IS THE OVER-REACH GUARD. Grants only ADD access, so a member
  carries no `:grant_scoped` flag and `maybe_scope_to_grants/2` is a provable
  no-op for her: identical NDJSON, identical revision list, identical revision
  detail. It is also the COLLIDING-FIXTURE proof — the out-of-grant row really
  is reachable on these routes, so the grantee refutes refute something that
  genuinely exists rather than passing on an empty response.

  Revisions bind the ladder DIRECTLY: `revisions` carries `project_id`,
  `dataset`, `type` and `doc_id` (schema `Barkpark.Content.Revision`, stamped
  from the source document by `Broadcast.save_revision/5`), which is exactly the
  ladder `Scope.grant_ladder_condition/1` walks — so no join to `documents` is
  needed, and none is introduced.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content, Tenancy}

  @ds "production"
  @password "correct-horse-battery"

  # The type the grant COVERS, and the type it does NOT. Same workspace, same
  # project, same dataset — the ONLY thing separating the second from the caller
  # is the grant's `type` rung, so nothing but grant narrowing can hide it.
  @in_grant_type "grantedMemo"
  @out_of_grant_type "ledgerSecret"

  setup %{conn: conn} do
    ensure_default_scope!()

    ws_b = create_workspace!("export-victim-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "export-vp-#{System.unique_integer([:positive])}")

    {:ok, doc_in} =
      create_document_in!(ws_b, proj_b, @in_grant_type, %{"title" => "in-grant"}, @ds)

    {:ok, doc_out} =
      create_document_in!(ws_b, proj_b, @out_of_grant_type, %{"title" => "out-of-grant"}, @ds)

    # Alice: an ordinary signed-in user who is NOT a member of workspace B, with
    # her own workspace and a read token minted into it. Neither credential says
    # anything about B.
    email = "export-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, alice} = Accounts.register_user(%{email: email, password: @password})
    {:ok, alice_session} = Accounts.create_user_session_token(alice)

    ws_a = create_workspace!("export-alice-#{System.unique_integer([:positive])}")
    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, alice.id, "admin", "user")
    alice_raw = "alice-export-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(alice_raw, "alice-app", @ds, ["read"], ws_a.id)

    {:ok,
     conn: conn,
     ws_b: ws_b,
     proj_b: proj_b,
     doc_in: doc_in,
     doc_out: doc_out,
     rev_in: only_revision!(doc_in, ws_b, proj_b),
     rev_out: only_revision!(doc_out, ws_b, proj_b),
     alice: alice,
     alice_session: alice_session,
     alice_raw: alice_raw}
  end

  # The revision `create_document` wrote, read back through an UNSCOPED-by-grant
  # internal call (no `:grant_scoped` key) so the fixture cannot be hidden by the
  # very clamp under test.
  defp only_revision!(doc, ws, proj) do
    [rev | _] =
      Content.list_revisions(doc.doc_id, doc.type, @ds,
        workspace_id: ws.id,
        project_id: proj.id
      )

    rev
  end

  defp base(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data"
  defp export_path(ws, proj), do: "#{base(ws, proj)}/export/#{@ds}"

  defp history_path(ws, proj, doc),
    do: "#{base(ws, proj)}/history/#{@ds}/#{doc.type}/#{doc.doc_id}"

  defp revision_path(ws, proj, rev), do: "#{base(ws, proj)}/revision/#{@ds}/#{rev.id}"

  defp alice_conn(conn, %{alice_session: session, alice_raw: raw}) do
    conn
    |> Plug.Test.init_test_session(%{"user_session" => session})
    |> put_req_header("authorization", "Bearer " <> raw)
  end

  defp member_conn(conn, ws) do
    raw = "export-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "export-member", @ds, ["read"], ws.id)
    put_req_header(conn, "authorization", "Bearer " <> raw)
  end

  defp export_types(resp) do
    resp.resp_body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.map(& &1["_type"])
    |> Enum.sort()
  end

  describe "GRANTEE — a non-member holding a type-scoped read grant on B" do
    setup ctx do
      grant =
        bind_grant!(ctx.ws_b, ctx.alice, %{
          project_id: ctx.proj_b.id,
          dataset: @ds,
          type: @in_grant_type,
          capabilities: ["read"]
        })

      {:ok, grant: grant}
    end

    test "reaches the export door at all — the reachability precondition", ctx do
      conn = ctx.conn |> alice_conn(ctx) |> get(export_path(ctx.ws_b, ctx.proj_b))

      assert conn.status == 200,
             "PRECONDITION FAILED: the grant-derived caller did not reach " <>
               "ExportController over HTTP (#{conn.status} #{conn.resp_body}). " <>
               "Every assertion below would then be vacuous."
    end

    test "export streams ONLY the grant ladder — not the whole dataset", ctx do
      conn = ctx.conn |> alice_conn(ctx) |> get(export_path(ctx.ws_b, ctx.proj_b))
      assert conn.status == 200
      types = export_types(conn)

      assert @in_grant_type in types,
             "the grant's OWN type must still export — narrowing must not blank " <>
               "the grantee's backup"

      refute @out_of_grant_type in types,
             "LEAK: the export streamed the FULL ENVELOPE of a document outside " <>
               "the caller's grant ladder (types seen: #{inspect(types)})"
    end

    test "history for an out-of-grant document is empty", ctx do
      conn =
        ctx.conn |> alice_conn(ctx) |> get(history_path(ctx.ws_b, ctx.proj_b, ctx.doc_out))

      body = json_response(conn, 200)

      assert body["count"] == 0,
             "LEAK: list_revisions returned #{body["count"]} revision(s) of a " <>
               "document outside the caller's grant ladder"
    end

    test "history for the grant's OWN document still works", ctx do
      conn =
        ctx.conn |> alice_conn(ctx) |> get(history_path(ctx.ws_b, ctx.proj_b, ctx.doc_in))

      body = json_response(conn, 200)

      assert body["count"] >= 1,
             "OVER-REACH: the clamp hid the grantee's OWN revision history"
    end

    test "revision detail for an out-of-grant revision is 404", ctx do
      conn =
        ctx.conn |> alice_conn(ctx) |> get(revision_path(ctx.ws_b, ctx.proj_b, ctx.rev_out))

      assert conn.status == 404,
             "LEAK: get_revision served the stored snapshot (title/status/content) " <>
               "of a document outside the caller's grant ladder " <>
               "(#{conn.status} #{conn.resp_body})"
    end

    test "revision detail for the grant's OWN revision still resolves", ctx do
      conn =
        ctx.conn |> alice_conn(ctx) |> get(revision_path(ctx.ws_b, ctx.proj_b, ctx.rev_in))

      body = json_response(conn, 200)

      assert body["revision"]["type"] == @in_grant_type,
             "OVER-REACH: the clamp hid the grantee's OWN revision detail"
    end
  end

  describe "MEMBER — byte-identical (grants only ADD access, so the call is a no-op)" do
    test "export NDJSON still carries EVERY type in the dataset", ctx do
      conn = ctx.conn |> member_conn(ctx.ws_b) |> get(export_path(ctx.ws_b, ctx.proj_b))
      assert conn.status == 200
      types = export_types(conn)

      assert @in_grant_type in types
      assert @out_of_grant_type in types, "OVER-REACH: the clamp hid a member's own document"
    end

    test "history and revision detail are unchanged for a member", ctx do
      member = fn -> member_conn(ctx.conn, ctx.ws_b) end

      out_history =
        member.() |> get(history_path(ctx.ws_b, ctx.proj_b, ctx.doc_out)) |> json_response(200)

      assert out_history["count"] >= 1,
             "OVER-REACH: the clamp hid a member's own revision history"

      out_rev =
        member.() |> get(revision_path(ctx.ws_b, ctx.proj_b, ctx.rev_out)) |> json_response(200)

      assert out_rev["revision"]["type"] == @out_of_grant_type,
             "OVER-REACH: the clamp hid a member's own revision detail"
    end
  end
end
