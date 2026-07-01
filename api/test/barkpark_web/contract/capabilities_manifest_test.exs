defmodule BarkparkWeb.Contract.CapabilitiesManifestTest do
  @moduledoc """
  Manifest-vs-server contract pins for core commands.

  These are regression guards for the two contract bugs found by the
  typed-verbatim audit (2026-06-10):

    BUG 1 — doc.query flag must be named "filter" (not "query") so bp sends
             ?filter=<expr>, which QueryController reads via params["filter"].
             A scalar ?filter=field=value or ?filter=field==value is now parsed
             by normalize_filter_map/1 as an equality filter.

    BUG 2 — media.upload path must be /v1/media/:dataset/upload (the real
             POST route); the bare /v1/media/:dataset has no POST handler and
             returns 404.
  """
  use BarkparkWeb.ConnCase, async: true

  @token "barkpark-dev-token"

  setup do
    # CI boots a COLD test DB (`mix ecto.create && mix ecto.migrate` — seeds
    # never run), so no api_tokens row exists unless the test inserts one.
    # Without it the Bearer header resolves to no token, the caller projects
    # at tier "none", and existence-hiding strips media.upload (auth_tier
    # "write") from the manifest — doc.query (tier "none") still passes, which
    # is exactly the asymmetric CI failure this setup prevents. Locally a
    # committed dev-token row may already exist in barkpark_test; this insert
    # then fails on the token_hash unique constraint and the committed row
    # serves the same role (same tolerant pattern as the sibling contract
    # tests, e.g. search_settings_test.exs). Sandboxed, so seed-order and
    # async-safe.
    Barkpark.Auth.create_token(@token, "dev", "test", ["read", "write", "admin"])
    :ok
  end

  defp capabilities(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get("/v1/capabilities")
    |> json_response(200)
  end

  defp find_cmd(manifest, id) do
    manifest["commands"] |> Enum.find(&(&1["id"] == id))
  end

  describe "doc.query manifest contract (BUG 1)" do
    test "doc.query flag is named 'filter', not 'query'", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "doc.query")

      assert cmd != nil, "doc.query command not found in manifest"

      flag_names = Enum.map(cmd["flags"], & &1["name"])

      assert "filter" in flag_names,
             "doc.query must declare flag 'filter'; got: #{inspect(flag_names)}"

      refute "query" in flag_names,
             "doc.query must NOT declare a flag named 'query' (maps to wrong param name)"
    end

    test "doc.query filter flag type is string", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "doc.query")
      filter_flag = Enum.find(cmd["flags"], &(&1["name"] == "filter"))

      assert filter_flag != nil
      assert filter_flag["type"] == "string"
    end
  end

  describe "search.query manifest contract" do
    test "search declares both `type` (single) and `types` (multi-type allowlist)", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "search.query")

      assert cmd != nil, "search.query command not found in manifest"

      flag_names = Enum.map(cmd["flags"], & &1["name"])
      # `type` scopes to one type; `types` is the comma-separated allowlist the
      # search API supports (parse_types) — so `bp search --types post,author`
      # can do a cross-type search, at parity with the SDK's SearchOptions.types.
      assert "type" in flag_names

      assert "types" in flag_names,
             "search.query must declare a `types` flag; got: #{inspect(flag_names)}"

      types_flag = Enum.find(cmd["flags"], &(&1["name"] == "types"))
      assert types_flag["type"] == "string"
    end
  end

  describe "media.upload path contract (BUG 2)" do
    test "media.upload path_template is /v1/media/:dataset/upload", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.upload")

      assert cmd != nil, "media.upload command not found in manifest"

      path = get_in(cmd, ["http", "path_template"])

      assert path == "/v1/media/:dataset/upload",
             "media.upload path_template should be '/v1/media/:dataset/upload'; got: #{inspect(path)}"
    end

    test "POST /v1/media/:dataset/upload route exists (not 404)", %{conn: conn} do
      # This verifies the real route is reachable (no handler mismatch).
      # We send an empty JSON body — the upload controller will reject it with
      # 400 or 422, but NOT 404. A 404 would mean the bare /v1/media/:dataset
      # path is still being used in the manifest.
      resp =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/media/production/upload", "{}")

      refute resp.status == 404,
             "POST /v1/media/production/upload must not 404 — check the capabilities path_template"
    end
  end

  describe "doc.discard-draft mutation command" do
    test "is present with mutation_op discardDraft + type/id args", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "doc.discard-draft")

      assert cmd != nil, "doc.discard-draft command not found in manifest"
      assert cmd["mutation_op"] == "discardDraft"

      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "type" in arg_names
      assert "id" in arg_names
    end
  end

  describe "media get/delete commands" do
    test "media.get is GET /v1/media/:dataset/:id with an id arg", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.get")

      assert cmd != nil, "media.get not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/:id"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    test "media.delete is DELETE /v1/media/:dataset/:id", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.delete")

      assert cmd != nil, "media.delete not found in manifest"
      assert cmd["http"]["method"] == "DELETE"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/:id"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    # CLI parity with the SDK's getAssetRelations / checkoutAsset /
    # undoCheckoutAsset (#584): the API + SDK have these asset ops; the manifest
    # must expose them too so `bp media relations|checkout|undo-checkout <id>` exist.
    test "media.relations is GET /v1/media/:dataset/:id/relations with an id arg", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.relations")

      assert cmd != nil, "media.relations not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/:id/relations"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    test "media.checkout is POST /v1/media/:dataset/:id/checkout with an id arg", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.checkout")

      assert cmd != nil, "media.checkout not found in manifest"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/:id/checkout"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    test "media.undo-checkout is POST /v1/media/:dataset/:id/undo-checkout", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.undo-checkout")

      assert cmd != nil, "media.undo-checkout not found in manifest"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/:id/undo-checkout"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    # CLI parity with the SDK's searchAssets (#585). `q` is an OPTIONAL positional
    # (required=false) so `bp media search cat` and a filter-only `bp media search
    # --collection c1` both work — the API allows a blank query.
    test "media.search is GET /v1/media/:dataset/search with an optional q + filter flags",
         %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.search")

      assert cmd != nil, "media.search not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/search"

      q = Enum.find(cmd["args"], &(&1["name"] == "q"))
      assert q != nil, "media.search must declare a q arg"
      assert q["required"] == false, "q must be OPTIONAL (filter-only browse)"

      flag_names = Enum.map(cmd["flags"], & &1["name"])
      assert "type" in flag_names
      assert "tags" in flag_names
      assert "collection" in flag_names
      assert "limit" in flag_names
    end
  end

  describe "schema.ls command" do
    test "is GET /v1/schemas/:dataset (list all schemas, no name arg)", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "schema.ls")

      assert cmd != nil, "schema.ls not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/schemas/:dataset"
      assert cmd["args"] == []
    end
  end

  describe "schema.delete command" do
    test "is DELETE /v1/schemas/:dataset/:name with a required name arg", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "schema.delete")

      # The SDK has deleteSchema and the API exposes DELETE /v1/schemas/:dataset/:name;
      # the CLI manifest must expose it too so `bp schema delete <name>` exists.
      assert cmd != nil, "schema.delete not found in manifest"
      assert cmd["http"]["method"] == "DELETE"
      assert cmd["http"]["path_template"] == "/v1/schemas/:dataset/:name"
      assert "name" in Enum.map(cmd["args"], & &1["name"])
      # Schema management is admin-tier + scoped, matching schema.apply.
      assert cmd["auth_tier"] == "admin"
    end
  end

  describe "workspace.project-ls command" do
    test "is GET /api/workspaces/:workspace_slug/projects with no args", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "workspace.project-ls")

      assert cmd != nil, "workspace.project-ls not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/api/workspaces/:workspace_slug/projects"
      # :workspace_slug resolves from the active --workspace context, not an arg.
      assert cmd["args"] == []
    end
  end

  describe "webhook get/delete commands" do
    test "webhook.get is GET /v1/webhooks/:dataset/:id with an id arg", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "webhook.get")

      assert cmd != nil, "webhook.get not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/webhooks/:dataset/:id"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    test "webhook.delete is DELETE /v1/webhooks/:dataset/:id (admin)", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "webhook.delete")

      assert cmd != nil, "webhook.delete not found in manifest"
      assert cmd["http"]["method"] == "DELETE"
      assert cmd["http"]["path_template"] == "/v1/webhooks/:dataset/:id"
      assert cmd["auth_tier"] == "admin"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    test "webhook.update is PUT /v1/webhooks/:dataset/:id with id + url args (admin)", %{
      conn: conn
    } do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "webhook.update")

      assert cmd != nil, "webhook.update not found in manifest"
      assert cmd["http"]["method"] == "PUT"
      assert cmd["http"]["path_template"] == "/v1/webhooks/:dataset/:id"
      assert cmd["auth_tier"] == "admin"
      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "id" in arg_names
      assert "url" in arg_names
    end

    test "webhook.create is admin-tier — matches the require_admin route block", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "webhook.create")

      assert cmd != nil, "webhook.create not found in manifest"
      assert cmd["auth_tier"] == "admin"
    end
  end

  describe "media collection commands" do
    test "media.collections is GET /v1/media/:dataset/collections (no id arg)", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.collections")

      assert cmd != nil, "media.collections not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/collections"
      assert cmd["args"] == [] or cmd["args"] == nil
    end

    test "media.collection-assets is GET .../collections/:id/assets with an id arg", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.collection-assets")

      assert cmd != nil, "media.collection-assets not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/collections/:id/assets"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end
  end

  describe "doc backlinks command" do
    test "doc.backlinks is GET /v1/data/backlinks/:dataset/:id (read tier, id arg)", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "doc.backlinks")

      assert cmd != nil, "doc.backlinks not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/data/backlinks/:dataset/:id"
      # backlinks requires a token (the endpoint 404s anon), so it is read-tier,
      # not "none" like the schema-visibility-gated public doc reads.
      assert cmd["auth_tier"] == "read"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end
  end

  describe "doc history commands" do
    test "doc.history is GET /v1/data/history/:dataset/:type/:doc_id (read, type+doc_id)", %{
      conn: conn
    } do
      cmd = find_cmd(capabilities(conn), "doc.history")
      assert cmd != nil, "doc.history not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/data/history/:dataset/:type/:doc_id"
      assert cmd["auth_tier"] == "read"
      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "type" in arg_names
      assert "doc_id" in arg_names
    end

    test "doc.revision is GET /v1/data/revision/:dataset/:rev_id (read, rev_id)", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "doc.revision")
      assert cmd != nil, "doc.revision not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/data/revision/:dataset/:rev_id"
      assert cmd["auth_tier"] == "read"
      assert "rev_id" in Enum.map(cmd["args"], & &1["name"])
    end

    test "doc.restore-revision is POST .../restore (write, rev_id+type)", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "doc.restore-revision")
      assert cmd != nil, "doc.restore-revision not found in manifest"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/data/revision/:dataset/:rev_id/restore"
      assert cmd["auth_tier"] == "write"
      assert cmd["writes"] == true
      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "rev_id" in arg_names
      assert "type" in arg_names
    end
  end

  describe "auth MFA commands carry the re-auth password" do
    # The server's mfa_enroll/verify/disable all pattern-match a `password` in the
    # body (MEDIUM-8 re-auth); a command missing it 422s "password required".
    test "auth.mfa-enroll has a password arg", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "auth.mfa-enroll")
      assert cmd != nil, "auth.mfa-enroll not found"
      assert "password" in Enum.map(cmd["args"], & &1["name"])
    end

    test "auth.mfa-verify carries secret + code + password", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "auth.mfa-verify")
      assert cmd != nil, "auth.mfa-verify not found"
      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "secret" in arg_names
      assert "code" in arg_names
      assert "password" in arg_names
    end

    test "auth.mfa-disable is POST /v1/auth/mfa/disable with a password arg", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "auth.mfa-disable")
      assert cmd != nil, "auth.mfa-disable not found"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/auth/mfa/disable"
      assert "password" in Enum.map(cmd["args"], & &1["name"])
    end
  end

  describe "media collection membership commands (server param asymmetry)" do
    # add_member reads `assetId` from the BODY; remove_member reads `:asset_id`
    # from the PATH — the manifest must mirror both exactly or the commands 422.
    test "media.add-member is POST .../members (write) with id + assetId (body)", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "media.add-member")
      assert cmd != nil, "media.add-member not found"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/collections/:id/members"
      assert cmd["auth_tier"] == "write"
      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "id" in arg_names
      # camelCase, NOT a path placeholder — it must land in the body as `assetId`.
      assert "assetId" in arg_names
      refute cmd["http"]["path_template"] =~ "assetId"
    end

    test "media.remove-member is DELETE .../members/:asset_id (write) with id + asset_id (path)",
         %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "media.remove-member")
      assert cmd != nil, "media.remove-member not found"
      assert cmd["http"]["method"] == "DELETE"

      assert cmd["http"]["path_template"] ==
               "/v1/media/:dataset/collections/:id/members/:asset_id"

      assert cmd["auth_tier"] == "write"
      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "id" in arg_names
      # snake_case, matches the `:asset_id` PATH placeholder (not the body).
      assert "asset_id" in arg_names
    end
  end

  describe "media collection share commands" do
    test "media.share-collection is POST .../share (write) with id + ttl flag", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "media.share-collection")
      assert cmd != nil, "media.share-collection not found"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/collections/:id/share"
      assert cmd["auth_tier"] == "write"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
      assert "ttl" in Enum.map(cmd["flags"], & &1["name"])
    end

    test "media.revoke-share is DELETE .../share (write) with an id arg", %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "media.revoke-share")
      assert cmd != nil, "media.revoke-share not found"
      assert cmd["http"]["method"] == "DELETE"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/collections/:id/share"
      assert cmd["auth_tier"] == "write"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end
  end
end
