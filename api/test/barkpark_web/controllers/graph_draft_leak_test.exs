defmodule BarkparkWeb.GraphDraftLeakTest do
  @moduledoc """
  SECURITY seal for the graph root draft-existence/title leak
  (task-d223068f55efbf47, api-read-path-security-sweep wave 2026-08-17).

  THE LEAK: `resolve_graph_root/2` matched `d.doc_id == pub_id OR draft` with a
  published-preferred `order_by`, so a DRAFT-ONLY id (no published twin) fell
  back to its `drafts.<id>` row at the DEFAULT (published) perspective. Any
  plain read token calling `GET /v1/graph/<draft-only id>` got a 200 that
  confirmed the draft's existence and echoed its real title through the
  traversal — live-proven on guerrilla with `gh-9531`.

  THE SEAL (load-bearing): `resolve_graph_root/2` now honours the requested
  perspective — a default/published-perspective request resolves ONLY a
  published root (draft-only id -> 404), while an explicit drafts-perspective
  request from a permitted tier still resolves the draft root. Both callers
  (`graph_show`, `graph_tasks`) route through it, so both are covered.

  MUTATION PROOF: reverting the perspective gate in `resolve_graph_root/2`
  (restoring the unconditional `pub OR draft` fallback) reds the LOAD-BEARING
  tests below; the fix restores green. The AnonPerspective reroute in
  `graph_traverse_opts` is defense-in-depth only — public-read is already 403
  at the route (asserted below), so that clamp is NOT the proof.

  SECOND PIN (wave 2, arpss-wave1-residue-pins): the gate holds only because
  `resolve_graph_root/2` normalises the REQUEST id (`pub_id =
  Content.published_id(id)`) before the published-only match — otherwise
  `GET /v1/graph/drafts.<id>` names the draft row directly and walks straight
  past the perspective gate. Mutation proof: changing that line to
  `pub_id = id` reds ONLY the two `drafts.<id>` arms below; every other test
  here stays green.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @read_token "barkpark-test-graph-leak-read"
  @admin_token "barkpark-test-graph-leak-admin"
  @public_read_token "barkpark-test-graph-leak-public"
  @dataset "production"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    # A PLAIN read token — the attacker tier from the live repro: any shipped
    # or leaked read credential, no draft permissions implied.
    {:ok, _} = Auth.create_token(@read_token, "graph-leak-read", @dataset, ["read"])

    {:ok, _} =
      Auth.create_token(@admin_token, "graph-leak-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} =
      Auth.create_token(@public_read_token, "graph-leak-public", @dataset, ["public-read"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp bearer(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A draft-only doc: created but NEVER published — its only row is the
  # `drafts.<id>` twin, exactly the shape of the live `gh-9531` repro.
  defp mk_draft_only!(doc_id, title, scope) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => title, "content" => %{}},
        @dataset,
        scope
      )

    doc
  end

  describe "the LOAD-BEARING gate: default perspective resolves ONLY a published root" do
    test "GET /v1/graph/:id for a draft-only id is 404 and never echoes the draft title",
         %{conn: conn, scope: scope} do
      doc_id = uniq("leak-root")
      secret_title = "DRAFT-SECRET-#{doc_id}"
      mk_draft_only!(doc_id, secret_title, scope)

      resp = conn |> bearer(@read_token) |> get("/v1/graph/#{doc_id}")

      assert resp.status == 404,
             "draft-only id resolved at the DEFAULT perspective (got #{resp.status}) — " <>
               "resolve_graph_root fell back to the drafts.<id> row: #{resp.resp_body}"

      refute resp.resp_body =~ secret_title,
             "the draft's real title leaked through /v1/graph/:id at the default perspective"
    end

    test "GET /v1/graph/:id/tasks for a draft-only id is 404 (same resolver, second caller)",
         %{conn: conn, scope: scope} do
      doc_id = uniq("leak-tasks-root")
      secret_title = "DRAFT-SECRET-#{doc_id}"
      mk_draft_only!(doc_id, secret_title, scope)

      resp = conn |> bearer(@read_token) |> get("/v1/graph/#{doc_id}/tasks")

      assert resp.status == 404,
             "graph_tasks resolved a draft-only root at the default perspective " <>
               "(got #{resp.status}): #{resp.resp_body}"

      refute resp.resp_body =~ secret_title
    end

    test "GET /v1/graph/drafts.<id> at the default perspective is 404 — the request id is normalised",
         %{conn: conn, scope: scope} do
      doc_id = uniq("leak-prefix-root")
      secret_title = "DRAFT-SECRET-#{doc_id}"
      mk_draft_only!(doc_id, secret_title, scope)

      # The attacker asks for the drafts. twin BY NAME. `pub_id =
      # Content.published_id(id)` strips the prefix BEFORE the published-only
      # match, so the default perspective still resolves nothing. Drop that
      # normalisation (`pub_id = id`) and this arm 200s the draft row straight
      # past the perspective gate.
      resp = conn |> bearer(@read_token) |> get("/v1/graph/drafts.#{doc_id}")

      assert resp.status == 404,
             "an explicitly drafts.-prefixed request id resolved at the DEFAULT " <>
               "perspective (got #{resp.status}) — the request id is not normalised " <>
               "before the published-only match: #{resp.resp_body}"

      refute resp.resp_body =~ secret_title,
             "the draft's real title leaked through /v1/graph/drafts.<id> at the default perspective"
    end

    test "GET /v1/graph/drafts.<id>/tasks at the default perspective is 404 (second caller)",
         %{conn: conn, scope: scope} do
      doc_id = uniq("leak-prefix-tasks")
      secret_title = "DRAFT-SECRET-#{doc_id}"
      mk_draft_only!(doc_id, secret_title, scope)

      resp = conn |> bearer(@read_token) |> get("/v1/graph/drafts.#{doc_id}/tasks")

      assert resp.status == 404,
             "graph_tasks resolved a drafts.-prefixed request id at the default " <>
               "perspective (got #{resp.status}): #{resp.resp_body}"

      refute resp.resp_body =~ secret_title
    end

    test "an EXPLICIT ?perspective=published request for a draft-only id is also 404",
         %{conn: conn, scope: scope} do
      doc_id = uniq("leak-explicit")
      mk_draft_only!(doc_id, "DRAFT-SECRET-#{doc_id}", scope)

      resp =
        conn
        |> bearer(@read_token)
        |> get("/v1/graph/#{doc_id}?perspective=published")

      assert resp.status == 404
    end
  end

  describe "fail-broken checks: legitimate reads are NOT regressed" do
    test "a member/admin token still resolves + traverses a draft-only root at ?perspective=drafts",
         %{conn: conn, scope: scope} do
      doc_id = uniq("leak-drafts-ok")
      mk_draft_only!(doc_id, "DRAFT-VISIBLE-#{doc_id}", scope)

      resp =
        conn
        |> bearer(@admin_token)
        |> get("/v1/graph/#{doc_id}?perspective=drafts")

      assert resp.status == 200,
             "drafts-perspective root resolution broke for a permitted tier " <>
               "(got #{resp.status}): #{resp.resp_body}"

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      # Published-coalesced root id — the graph identity, never the drafts. twin.
      assert body["root"] == doc_id
    end

    test "a PUBLISHED id still resolves at the default perspective for a plain read token",
         %{conn: conn, scope: scope} do
      doc_id = uniq("leak-published-ok")
      mk_draft_only!(doc_id, "PUBLISHED-#{doc_id}", scope)
      {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)

      resp = conn |> bearer(@read_token) |> get("/v1/graph/#{doc_id}")

      assert resp.status == 200,
             "published root stopped resolving at the default perspective — " <>
               "the gate over-clamped (got #{resp.status}): #{resp.resp_body}"

      assert Jason.decode!(resp.resp_body)["root"] == doc_id
    end
  end

  describe "public-read tier (defense-in-depth context, NOT the seal)" do
    test "public-read stays 403 at /v1/graph/:id — even asking for drafts", %{
      conn: conn,
      scope: scope
    } do
      doc_id = uniq("leak-public")
      mk_draft_only!(doc_id, "DRAFT-SECRET-#{doc_id}", scope)

      for path <- [
            "/v1/graph/#{doc_id}",
            "/v1/graph/#{doc_id}?perspective=drafts",
            "/v1/graph/#{doc_id}/tasks"
          ] do
        resp = conn |> bearer(@public_read_token) |> get(path)

        assert resp.status == 403,
               "#{path} returned #{resp.status} for public-read — expected 403 at the route"
      end
    end
  end
end
