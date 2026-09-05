defmodule BarkparkWeb.UnscopedWriteScopeTest do
  @moduledoc """
  THE UNSCOPED-WRITE RULING, at the door (task-6fa023cdabdc5f6a).

  Ratified on main 2026-09-05: an unscoped write is INFER-WHEN-UNAMBIGUOUS,
  REFUSE-WHEN-AMBIGUOUS, NEVER LOG-ONLY. Before it, a write that named no
  workspace — no `/w/:workspace_slug` in the path AND no `workspace_id` on the
  token — was stamped into the seeded Default Workspace by
  `Plugs.AssignDefaultScope`, silently, and nobody chose that. The write
  belonged to nobody and was recorded as belonging to one tenant.

  Three states, one door (`POST /v1/data/mutate/:dataset`):

    1. the credential can mean EXACTLY ONE workspace  -> infer it, stamp it,
       and NAME it back on the wire (`resolvedScope`);
    2. the credential can mean SEVERAL (or none)      -> typed 422
       `workspace_scope_required`, and NOTHING is written;
    3. the request named its own workspace            -> byte-identical to
       before, and no `resolvedScope` key appears.

  SCOPE NOTE (shared test database): every assertion is keyed on ids this test
  minted (its own workspaces, its own token, its own document id), so a
  parallel agent's rows cannot satisfy or break it. `async: false` because the
  seeded Default Workspace is process-global state the Default arm reads.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "test"

  setup do
    ws_a = TenancyFixtures.create_workspace!()
    _proj_a = TenancyFixtures.create_project!(ws_a, "default")
    ws_b = TenancyFixtures.create_workspace!()
    _proj_b = TenancyFixtures.create_project!(ws_b, "default")

    # The schema must be resolvable in EVERY workspace the writes land in, or
    # the mutate 404s `schema_unknown` before scope resolution is reached and
    # the test proves nothing about scope.
    for ws <- [ws_a, ws_b] do
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        workspace_id: ws.id
      )
    end

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    {:ok, ws_a: ws_a, ws_b: ws_b}
  end

  # A HOMELESS token: `workspace_id` NULL, so `Plugs.DeriveWorkspaceFromToken`
  # no-ops and `AssignDefaultScope` used to stamp Default. Minted through the
  # changeset rather than `Auth.create_token/5`, whose `workspace_id` argument
  # DEFAULTS to the seeded Default id — a token minted that way is never
  # homeless and could not reach the state under test.
  defp homeless_token!(raw, member_of) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "unscoped-write-ruling",
        dataset: @dataset,
        permissions: ["read", "write"],
        workspace_id: nil
      })
      |> Repo.insert()

    for ws <- member_of do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")
    end

    token
  end

  defp send_create(conn, raw_token, doc_id) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_token}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{"create" => %{"_id" => doc_id, "_type" => "post", "title" => "w41"}}
        ]
      })
    )
  end

  describe "INFER — the credential can mean exactly one workspace" do
    test "the write lands in that workspace and the response NAMES it", %{
      conn: conn,
      ws_a: ws_a
    } do
      raw = "w41-one-#{System.unique_integer([:positive])}"
      _token = homeless_token!(raw, [ws_a])
      doc_id = "w41-infer-#{System.unique_integer([:positive])}"

      resp = send_create(scoped_conn_from(conn), raw, doc_id)
      refute_rate_limited!(resp)

      assert resp.status == 200, "expected the inferred write to succeed, got #{resp.status}"
      body = Jason.decode!(resp.resp_body)

      assert body["resolvedScope"]["workspaceId"] == ws_a.id,
             "the response must NAME the workspace it inferred"

      assert body["resolvedScope"]["workspaceSlug"] == ws_a.slug

      doc = Repo.get_by(Document, doc_id: doc_id, type: "post")
      assert doc, "the inferred write must have landed a row"

      assert doc.workspace_id == ws_a.id,
             "the row must land in the ONE workspace the token can mean, " <>
               "not the seeded Default"
    end
  end

  describe "REFUSE — the credential is ambiguous" do
    test "a two-workspace token is refused 422 and writes NOTHING", %{
      conn: conn,
      ws_a: ws_a,
      ws_b: ws_b
    } do
      raw = "w41-two-#{System.unique_integer([:positive])}"
      _token = homeless_token!(raw, [ws_a, ws_b])
      doc_id = "w41-refuse-#{System.unique_integer([:positive])}"

      resp = send_create(scoped_conn_from(conn), raw, doc_id)
      refute_rate_limited!(resp)

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "workspace_scope_required"

      assert is_binary(body["error"]["hint"]) and
               String.contains?(body["error"]["hint"], "/w/:workspace_slug"),
             "a refusal must NAME the scope door to send instead"

      assert Enum.sort(body["error"]["details"]["workspaces"]) ==
               Enum.sort([ws_a.slug, ws_b.slug])

      refute Repo.get_by(Document, doc_id: doc_id, type: "post"),
             "a REFUSED write must leave no row — not in Default, not anywhere"
    end

    test "a platform token (no workspace, no memberships) is refused 422", %{conn: conn} do
      raw = "w41-platform-#{System.unique_integer([:positive])}"
      _token = homeless_token!(raw, [])
      doc_id = "w41-platform-#{System.unique_integer([:positive])}"

      resp = send_create(scoped_conn_from(conn), raw, doc_id)
      refute_rate_limited!(resp)

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "workspace_scope_required"
      assert body["error"]["details"]["workspaces"] == []

      refute Repo.get_by(Document, doc_id: doc_id, type: "post")
    end
  end

  describe "UNCHANGED — the request named its own workspace" do
    test "a workspace-bound token writes to its workspace with no resolvedScope key", %{
      conn: conn,
      ws_a: ws_a
    } do
      raw = "w41-bound-#{System.unique_integer([:positive])}"
      {:ok, _token} = Barkpark.Auth.create_token(raw, "bound", @dataset, ["read", "write"], ws_a.id)
      doc_id = "w41-bound-#{System.unique_integer([:positive])}"

      resp = send_create(scoped_conn_from(conn), raw, doc_id)
      refute_rate_limited!(resp)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      refute Map.has_key?(body, "resolvedScope"),
             "a request that said where it goes must get a byte-identical body"

      doc = Repo.get_by(Document, doc_id: doc_id, type: "post")
      assert doc.workspace_id == ws_a.id
    end
  end

  # `scoped_conn/0` mints its own conn; the ConnCase `%{conn: conn}` is already
  # built, so carry the per-test-process rate-limit scope onto it rather than
  # pooling into the shared `ip:127.0.0.1` bucket.
  defp scoped_conn_from(_conn), do: scoped_conn()
end
