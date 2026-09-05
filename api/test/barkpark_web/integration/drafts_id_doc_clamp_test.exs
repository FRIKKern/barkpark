defmodule BarkparkWeb.Integration.DraftsIdDocClampTest do
  @moduledoc """
  ROUTED regression cover for the `drafts.`-id doc clamp
  (`stw10-backlog-drafts-id-seam`, SECURITY p0).

  The seam: the doc pipeline's perspective clamp reads the QUERY PARAM
  (`?perspective=drafts` → 403 for a pinned caller) and, before the clamp, never
  inspected the doc ID. A `drafts.`-prefixed id addressed the draft row directly,
  so the shipped browser site token read full unpublished documents:

      GET /w/default/p/default/v1/data/doc/production/task/drafts.task-…  → 200, 7,557 bytes
      GET /v1/data/doc/production/paper/drafts.paper-…                    → 200, 110,639 bytes

  The clamp is ONE `cond` clause at the top of `QueryController.show/3`:

      AnonPerspective.anon_pinned?(conn) and String.starts_with?(doc_id, "drafts.") ->
        {:error, :not_found}

  ## Why this file exists

  Three routes reach that single clause and only ONE of them (the flat
  anonymous read) was covered. The W10 lesson is that a clamp re-probed on one
  of its surfaces produces a FALSE SEAL, so every surface is asserted here:

    * FLAT `/v1/data/doc/:dataset/:type/:doc_id` (`[:api, :api_grant_read]`)
    * SCOPED `/w/:ws/p/:project/v1/data/doc/…` (`:shared_docs_api`) — reached
      both by a public-read token AND by an anonymous holder of a `docs:read`
      share, which are two DIFFERENT ways of being `anon_pinned?`
    * SCOPED `/w/:ws/p/:project/v1/preview/doc/…` (`:scoped_api`) — this
      pipeline carries NEITHER a PreviewToken nor the PublicRead plug, so the
      controller clause is the route's ONLY guard. Nothing upstream would 403 a
      public-read token here.

  ## Fail-closed, not fail-broken

  `anon_pinned?/1` deliberately EXEMPTS an `:edit` share (an anonymous editing
  surface whose draft visibility is its contract) and every non-public-read
  token. Each negative case below is paired with a positive control that the
  SAME route serves the SAME draft 200 to a legitimate reader — a plain read
  token, or an anonymous `:edit`-share caller — so a 404 here can never be the
  route being broken, missing, or unreachable. The share describes additionally
  assert a 200 on the PUBLISHED twin, which proves the share grant actually
  fired (without that, the drafts 404 would be vacuous: an ungranted anonymous
  caller 404s for its own reason).

  ## Mutation proof (run in the builder's worktree, 2026-08-17)

  Baseline, clamp intact:

      $ CC=clang MIX_ENV=test mix test test/barkpark_web/integration/drafts_id_doc_clamp_test.exs
      9 tests, 0 failures

  Then the two-line `drafts.` cond clause in
  `lib/barkpark_web/controllers/query_controller.ex` `show/3` was commented out
  and the SAME command re-run — `9 tests, 5 failures`, every failure a leaked
  draft body (verbatim, trimmed to the first):

      1) test public-read token — a drafts. id is refused on the data doc routes
         404 on the FLAT doc route (no draft body)
         ** (RuntimeError) expected response with status 404, got: 200, with body:
         "{\\"result\\":{\\"_createdAt\\":\\"2026-08-17T07:31:51.872934Z\\",\\"_draft\\":true,
           \\"_id\\":\\"drafts.d1\\",\\"_publishedId\\":\\"d1\\",\\"_type\\":\\"post\\",
           \\"title\\":\\"DRAFTS-ID-LEAK-CANARY\\"}, …}"

  The other four reds were the SCOPED doc route, the `public-read`+`read` mixed
  token (flat), the anonymous `docs:read` share on the scoped doc route, and the
  SCOPED `/v1/preview/doc` route — each with the same `"_draft":true` /
  `DRAFTS-ID-LEAK-CANARY` body in the failure. All four positive controls stayed
  GREEN under the mutation, which is what makes them controls: the reds are the
  clamp being gone, not the fixtures or routes being broken.

  Restoring the clause returns the file to `9 tests, 0 failures`. No
  `query_controller.ex` change is committed with this file.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Sharing}

  import Barkpark.TenancyFixtures

  @dataset "production"

  # The canary title: it appears in NOTHING but the unpublished row, so if it
  # is ever visible in a response (or in a failure message) a draft leaked.
  @canary "DRAFTS-ID-LEAK-CANARY"

  defp public_schema!(scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    :ok
  end

  # `p1` published + `d1` draft-only. `drafts.d1` exists; the published `d1`
  # does NOT, so serving the draft is observable and resolving-to-published is
  # not silently indistinguishable from a leak.
  defp seed_docs!(scope) do
    {:ok, _} =
      Content.create_document("post", %{"_id" => "p1", "title" => "Live"}, @dataset, scope)

    {:ok, _} = Content.publish_document("p1", "post", @dataset, scope)

    {:ok, _} =
      Content.create_document("post", %{"_id" => "d1", "title" => @canary}, @dataset, scope)

    :ok
  end

  defp mint!(ws, permissions, label) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @dataset, permissions, ws.id)
    raw
  end

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp scoped_doc(ws, project, doc_id),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/doc/#{@dataset}/post/#{doc_id}"

  defp scoped_preview_doc(ws, project, doc_id),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/preview/doc/#{@dataset}/post/#{doc_id}"

  defp flat_doc(doc_id), do: "/v1/data/doc/#{@dataset}/post/#{doc_id}"

  # ── A public-read token: the browser-shipped site credential ───────────────
  #
  # `AnonPerspective.anon_pinned?/1` pins it exactly like an anonymous caller
  # (charter D60/D61), so it must be refused on BOTH doc routes. A plain `read`
  # token is the control: same routes, same draft, 200.
  describe "public-read token — a drafts. id is refused on the data doc routes" do
    setup do
      {ws, project} = ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      :ok = public_schema!(scope)
      :ok = seed_docs!(scope)

      %{
        ws: ws,
        project: project,
        public_read: mint!(ws, ["public-read"], "drafts-id public-read"),
        # What the PUBLIC mint route actually hands out when a caller asks for
        # both allowlisted permissions — membership, not list equality.
        mixed: mint!(ws, ["public-read", "read"], "drafts-id public-read+read"),
        read: mint!(ws, ["read"], "drafts-id read")
      }
    end

    test "404 on the FLAT doc route (no draft body)", %{conn: conn, public_read: token} do
      response = conn |> authed(token) |> get(flat_doc("drafts.d1"))

      assert json_response(response, 404)["error"]["code"] == "not_found"
      refute response.resp_body =~ @canary
    end

    test "404 on the SCOPED doc route (no draft body)", %{
      conn: conn,
      ws: ws,
      project: project,
      public_read: token
    } do
      response = conn |> authed(token) |> get(scoped_doc(ws, project, "drafts.d1"))

      assert json_response(response, 404)["error"]["code"] == "not_found"
      refute response.resp_body =~ @canary
    end

    test "a public-read + read token does NOT bypass the clamp either", %{
      conn: conn,
      ws: ws,
      project: project,
      mixed: token
    } do
      assert conn |> authed(token) |> get(flat_doc("drafts.d1")) |> json_response(404)

      assert conn
             |> authed(token)
             |> get(scoped_doc(ws, project, "drafts.d1"))
             |> json_response(404)
    end

    test "the PUBLISHED doc still reads 200 — the clamp is id-shaped, not route-wide", %{
      conn: conn,
      ws: ws,
      project: project,
      public_read: token
    } do
      assert conn
             |> authed(token)
             |> get(flat_doc("p1"))
             |> json_response(200)
             |> get_in(["result", "_id"]) == "p1"

      assert conn
             |> authed(token)
             |> get(scoped_doc(ws, project, "p1"))
             |> json_response(200)
             |> get_in(["result", "_id"]) == "p1"
    end

    # POSITIVE CONTROL (fail-closed, not fail-broken): a plain read token is a
    # legitimate draft-by-id reader — Studio preview and the editor address
    # drafts this way — and must be untouched on both routes.
    test "a plain read token still gets 200-with-draft on flat and scoped doc", %{
      conn: conn,
      ws: ws,
      project: project,
      read: token
    } do
      flat = conn |> authed(token) |> get(flat_doc("drafts.d1")) |> json_response(200)
      assert flat["result"]["_id"] == "drafts.d1"
      assert flat["result"]["title"] == @canary

      scoped =
        conn
        |> authed(token)
        |> get(scoped_doc(ws, project, "drafts.d1"))
        |> json_response(200)

      assert scoped["result"]["_id"] == "drafts.d1"
      assert scoped["result"]["title"] == @canary
    end
  end

  # ── An ANONYMOUS caller holding a share ───────────────────────────────────
  #
  # The second way to be `anon_pinned?`: no token at all, admitted to the scoped
  # route by `RequireShareScope` on a `:docs` share. A `:read` share is pinned
  # (404 on a drafts. id); an `:edit` share is deliberately EXEMPT (drafts are
  # its contract). Two distinct workspaces so one env holds both shares.
  describe "anonymous share caller — :read is clamped, :edit is exempt" do
    setup do
      read_ws = create_workspace!("drafts-id-read-ws")
      read_proj = create_project!(read_ws, "drafts-id-read-proj")
      edit_ws = create_workspace!("drafts-id-edit-ws")
      edit_proj = create_project!(edit_ws, "drafts-id-edit-proj")

      for {ws, proj} <- [{read_ws, read_proj}, {edit_ws, edit_proj}] do
        scope = [workspace_id: ws.id, project_id: proj.id]
        :ok = public_schema!(scope)
        :ok = seed_docs!(scope)
      end

      # arpss-w8: STORED rows, not a bare put_env — Sharing.refresh/0 rebuilds
      # them. NOTE the ";" separator: Sharing.parse/1 never splits on ",".
      Barkpark.SharingFixtures.plant_shares!(
        "#{read_ws.slug}/#{read_proj.slug}/#{@dataset}:docs:read;" <>
          "#{edit_ws.slug}/#{edit_proj.slug}/#{@dataset}:docs:edit"
      )

      %{
        read_ws: read_ws,
        read_proj: read_proj,
        edit_ws: edit_ws,
        edit_proj: edit_proj
      }
    end

    # NOT VACUOUS: the grant is proven live by the published-doc 200 in the same
    # test. Without it a 404 on the drafts id could just be an ungranted caller.
    test "a docs:read share serves the published doc (200) but 404s the drafts. id", %{
      conn: conn,
      read_ws: ws,
      read_proj: project
    } do
      published = conn |> get(scoped_doc(ws, project, "p1")) |> json_response(200)
      assert published["result"]["_id"] == "p1"

      response = conn |> get(scoped_doc(ws, project, "drafts.d1"))
      assert json_response(response, 404)["error"]["code"] == "not_found"
      refute response.resp_body =~ @canary
    end

    # POSITIVE CONTROL: `anon_pinned?/1` excludes an `:edit` share on purpose.
    test "a docs:edit share caller still gets 200-with-draft on the scoped doc route", %{
      conn: conn,
      edit_ws: ws,
      edit_proj: project
    } do
      body = conn |> get(scoped_doc(ws, project, "drafts.d1")) |> json_response(200)

      assert body["result"]["_id"] == "drafts.d1"
      assert body["result"]["title"] == @canary
    end
  end

  # ── The SCOPED preview doc route (`:scoped_api`) ───────────────────────────
  #
  # This pipeline mounts NEITHER PreviewToken (no `forced_perspective`) nor
  # PublicRead, so nothing upstream inspects the caller's tier: the `show/3`
  # cond clause is the ONLY guard standing between a public-read token and the
  # draft row. Membership is satisfied (the token is minted on this workspace),
  # which is precisely why membership is not a clamp.
  describe "scoped /v1/preview/doc — the controller clause is the only guard" do
    setup do
      ws = create_workspace!("drafts-id-preview-ws")
      project = create_project!(ws, "drafts-id-preview-proj")
      scope = [workspace_id: ws.id, project_id: project.id]

      :ok = public_schema!(scope)
      :ok = seed_docs!(scope)

      %{
        ws: ws,
        project: project,
        public_read: mint!(ws, ["public-read"], "drafts-id preview public-read"),
        read: mint!(ws, ["read"], "drafts-id preview read")
      }
    end

    test "a public-read token gets 404 on a drafts. id", %{
      conn: conn,
      ws: ws,
      project: project,
      public_read: token
    } do
      response = conn |> authed(token) |> get(scoped_preview_doc(ws, project, "drafts.d1"))

      assert json_response(response, 404)["error"]["code"] == "not_found"
      refute response.resp_body =~ @canary
    end

    # POSITIVE CONTROL: the route itself works and the draft row is reachable —
    # so the 404 above is the clamp, not a dead route or a missing fixture.
    test "a plain read token still gets 200-with-draft on the same preview route", %{
      conn: conn,
      ws: ws,
      project: project,
      read: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped_preview_doc(ws, project, "drafts.d1"))
        |> json_response(200)

      assert body["result"]["_id"] == "drafts.d1"
      assert body["result"]["title"] == @canary
    end
  end
end
