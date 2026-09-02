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
  # async: false — the `share.token-*` live-route describe block below mints a
  # real edit-token, which requires a live `:edit` share. Declaring one goes
  # through `Barkpark.Sharing.add_share/1`, which calls `refresh/0` and lands
  # the merged list in the process-global `:barkpark, :shares` Application env
  # (NOT Ecto-sandboxed, unlike the DB row behind it) — the exact hazard
  # `share_controller_test.exs` names in its own `async: false`. This file
  # must serialize with that sync group rather than race it.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  import Barkpark.TenancyFixtures

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

  # Bearer helper for the undeclared-verb-family invocation tests below — a
  # SECOND, test-local token distinct from @token/capabilities/1 (those two
  # are reserved for the manifest-shape assertions throughout this file).
  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_app_env(key, value), do: Application.put_env(:barkpark, key, value)

  # Raw request → the conn, so a test can read both the decoded body and the
  # `etag` response header / raw bytes off the same response.
  defp caps_conn(conn, query \\ "") do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get("/v1/capabilities" <> query)
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

    test "search declares the `fields` projection flag (controller already threads it)",
         %{conn: conn} do
      # The search controller (search/2 + search_local/2) already projects each
      # hit through `params["fields"]`, but the flag was undeclared — an agent
      # reading the manifest could not discover the token-thrifty projection.
      # This closes that pure declaration gap.
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "search.query")

      assert cmd != nil, "search.query command not found in manifest"

      fields_flag = Enum.find(cmd["flags"], &(&1["name"] == "fields"))

      assert fields_flag != nil,
             "search.query must declare a `fields` flag; got: " <>
               "#{inspect(Enum.map(cmd["flags"], & &1["name"]))}"

      assert fields_flag["type"] == "string"
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

  describe "dataset.stats analytics command" do
    test "is present as GET /v1/data/analytics/:dataset", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "dataset.stats")

      assert cmd != nil, "dataset.stats command not found in manifest"

      path = get_in(cmd, ["http", "path_template"])

      assert path == "/v1/data/analytics/:dataset",
             "dataset.stats path_template should be '/v1/data/analytics/:dataset'; got: #{inspect(path)}"
    end

    test "GET /v1/data/analytics/:dataset route exists (not 404)", %{conn: conn} do
      # Grounds the manifest path against the real route (analytics has a flat
      # mirror, so no workspace/project fixture is needed). A 404 would mean the
      # dataset.stats path_template points at a non-route.
      resp =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/data/analytics/production")

      refute resp.status == 404,
             "GET /v1/data/analytics/production must not 404 — check the dataset.stats path_template"
    end

    # drafts.loop-low-dataset-noun-orphan: dataset.stats' noun ("dataset") was
    # used by the verb but NOT declared in core_nouns — an orphan (no summary in
    # the manifest, a dangling OpenAPI tag). The noun a core verb uses must be a
    # declared noun.
    test "the `dataset` noun the verb uses is a declared manifest noun", %{conn: conn} do
      manifest = capabilities(conn)

      cmd = find_cmd(manifest, "dataset.stats")
      assert cmd["noun"] == "dataset"

      noun_names = Enum.map(manifest["nouns"], & &1["name"])

      assert "dataset" in noun_names,
             "manifest advertises verb dataset.stats (noun 'dataset') but declares no 'dataset' noun; " <>
               "declared nouns: #{inspect(noun_names)}"
    end
  end

  describe "workspace.create tier contract" do
    # drafts.loop-low-workspace-create-tier: POST /api/workspaces sits behind
    # `[:api, :require_token]` (RequireToken only — no :require_write), so any
    # authenticated token, including a read-only one, may create a workspace. The
    # manifest tier must mirror that floor (`read`) or existence-hiding wrongly
    # strips the verb from a read-tier caller who can actually invoke it.
    test "workspace.create is auth_tier 'read' (RequireToken-only route)", %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "workspace.create")

      assert cmd != nil, "workspace.create command not found in manifest"

      assert cmd["auth_tier"] == "read",
             "workspace.create auth_tier should be 'read' (route is RequireToken-only); " <>
               "got: #{inspect(cmd["auth_tier"])}"
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

    # CLI parity with the SDK's updateAsset (#582). PATCH the asset's metadata via
    # a repeatable --set flag; with no set_key/mutation_op the CLI builds a FLAT
    # body ({altText, tags, …}), matching what the PATCH route reads.
    test "media.update is PATCH /v1/media/:dataset/:id with id + a repeatable set flag",
         %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.update")

      assert cmd != nil, "media.update not found in manifest"
      assert cmd["http"]["method"] == "PATCH"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/:id"
      assert "id" in Enum.map(cmd["args"], & &1["name"])

      set = Enum.find(cmd["flags"], &(&1["name"] == "set"))
      assert set != nil, "media.update must declare a --set flag"
      assert set["repeatable"] == true, "--set must be repeatable"
      # No set_key wrapper → the --set fields land flat in the PATCH body.
      refute Map.has_key?(cmd, "set_key")
    end

    # CLI parity with the SDK's getAssetSearchSuggestions (#609): the API +
    # SDK have media search typeahead; the manifest must expose it so
    # `bp media suggest [q]` exists. `q` is optional (unfiltered top lists).
    test "media.suggest is GET /v1/media/:dataset/search/suggestions with an optional q",
         %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "media.suggest")

      assert cmd != nil, "media.suggest not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/media/:dataset/search/suggestions"

      q = Enum.find(cmd["args"], &(&1["name"] == "q"))
      assert q != nil, "media.suggest must declare a q arg"
      assert q["required"] == false, "q must be OPTIONAL (unfiltered top lists)"
      assert "limit" in Enum.map(cmd["flags"], & &1["name"])
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

  describe "workspace.dataset-ls command" do
    test "is GET /api/workspaces/:workspace_slug/projects/:project_slug/datasets with no args",
         %{conn: conn} do
      manifest = capabilities(conn)
      cmd = find_cmd(manifest, "workspace.dataset-ls")

      assert cmd != nil, "workspace.dataset-ls not found in manifest"
      assert cmd["http"]["method"] == "GET"

      assert cmd["http"]["path_template"] ==
               "/api/workspaces/:workspace_slug/projects/:project_slug/datasets"

      # :workspace_slug + :project_slug resolve from --workspace / --project, not args.
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

  describe "webhook console commands (C5 delivery log / replay / rotate)" do
    # The C5 operator-console routes (deliveries/replay/rotate) exist on the API
    # but were missing from the manifest — so `bp` and the cloud SPA couldn't
    # drive them through the capability contract. These pin the three entries.
    test "webhook.deliveries is GET /v1/webhooks/:dataset/:id/deliveries (admin, id arg)",
         %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "webhook.deliveries")

      assert cmd != nil, "webhook.deliveries not found in manifest"
      assert cmd["http"]["method"] == "GET"
      assert cmd["http"]["path_template"] == "/v1/webhooks/:dataset/:id/deliveries"
      assert cmd["auth_tier"] == "admin"
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    test "webhook.replay is POST .../deliveries/:event_id/replay (admin, writes, id+event_id)",
         %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "webhook.replay")

      assert cmd != nil, "webhook.replay not found in manifest"
      assert cmd["http"]["method"] == "POST"

      assert cmd["http"]["path_template"] ==
               "/v1/webhooks/:dataset/:id/deliveries/:event_id/replay"

      assert cmd["auth_tier"] == "admin"
      assert cmd["writes"] == true
      arg_names = Enum.map(cmd["args"], & &1["name"])
      assert "id" in arg_names
      assert "event_id" in arg_names
    end

    test "webhook.rotate is POST /v1/webhooks/:dataset/:id/rotate (admin, writes, id arg)",
         %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "webhook.rotate")

      assert cmd != nil, "webhook.rotate not found in manifest"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/webhooks/:dataset/:id/rotate"
      assert cmd["auth_tier"] == "admin"
      assert cmd["writes"] == true
      assert "id" in Enum.map(cmd["args"], & &1["name"])
    end

    # router.ex mounts POST /v1/webhooks/:dataset/:id/reenable
    # (webhook_controller.ex) alongside deliveries/replay/rotate above, but the
    # manifest carried its three siblings and not this one — undiscoverable by
    # `bp`/the cloud SPA. This pins the fourth C5 entry to the same shape.
    test "webhook.reenable is POST /v1/webhooks/:dataset/:id/reenable (admin, writes, id arg)",
         %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "webhook.reenable")

      assert cmd != nil, "webhook.reenable not found in manifest"
      assert cmd["http"]["method"] == "POST"
      assert cmd["http"]["path_template"] == "/v1/webhooks/:dataset/:id/reenable"
      assert cmd["auth_tier"] == "admin"
      assert cmd["writes"] == true
      assert "id" in Enum.map(cmd["args"], & &1["name"])
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

  describe "build identity section (instance self-update)" do
    # Opt-in by contract: released bp binaries strict-decode the manifest
    # (DisallowUnknownFields), so the default response must NEVER grow a new
    # root key. ?build=1 is the escape hatch new clients use.
    test "default manifest carries NO build section (old-CLI compatibility)", %{conn: conn} do
      manifest = capabilities(conn)
      refute Map.has_key?(manifest, "build")
    end

    test "?build=1 adds the build section with version/commit/built_at", %{conn: conn} do
      manifest =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/capabilities?build=1")
        |> json_response(200)

      build = manifest["build"]

      assert build != nil, "?build=1 must add a top-level 'build' section"

      # A.B.C.D (D = commits since the vA.B.C tag) or the fail-closed "unknown".
      assert build["version"] =~ ~r/^(\d+\.\d+\.\d+\.\d+|unknown)$/

      assert is_binary(build["release"]) and build["release"] != ""
      assert is_binary(build["commit"]) and build["commit"] != ""
      assert is_binary(build["built_at"]) and build["built_at"] != ""
    end

    test "anonymous callers get no build section even with ?build=1", %{conn: conn} do
      manifest =
        conn
        |> get("/v1/capabilities?build=1")
        |> json_response(200)

      refute Map.has_key?(manifest, "build")
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

  describe "chat transport commands (charter bp-chat-tui, ct-bl-manifest-commands)" do
    # bp chat was invisible to the capabilities manifest — the MCP bridge
    # (--tools all), SDK codegen, and headless harnesses could not discover it.
    # These pin the `chat` noun + the twelve non-streaming admin verbs mapped to
    # the already-shipped /v1/chat routes (SSE events is a builtin carve-out with
    # no manifest verb). StudioChat is core-embedded, NOT a Barkpark.Plugin, so
    # the noun is declared in core_nouns/0, not plugin_nouns/2.
    #
    # The two attachment verbs (ct-bl-chat-attachments) belong to THIS set and
    # not to the media noun on purpose: chat bytes are gated by the chat tenant
    # oracle, never by the any-token-public `GET /media/files/*` (charter D16).
    @chat_commands ~w(
      chat.create_session chat.list_sessions chat.get_session chat.update_session
      chat.send_message chat.interrupt chat.approve chat.answer chat.archive
      chat.unarchive chat.upload_attachment chat.get_attachment
    )

    test "the `chat` noun is declared and names the SSE streaming carve-out", %{conn: conn} do
      manifest = capabilities(conn)

      noun = Enum.find(manifest["nouns"], &(&1["name"] == "chat"))
      assert noun != nil, "manifest declares no `chat` noun"
      # StudioChat is core-embedded — the noun carries no plugin provenance.
      assert noun["plugin"] == nil

      # The events route is manifest-absent but must be discoverable via the
      # summary so a reading agent knows streaming exists via `bp chat`.
      assert noun["summary"] =~ ~r/stream/i,
             "chat noun summary must name the SSE streaming carve-out; got: #{inspect(noun["summary"])}"
    end

    test "exactly the twelve non-streaming chat verbs are registered (events stays absent)",
         %{conn: conn} do
      manifest = capabilities(conn)

      chat_ids =
        manifest["commands"]
        |> Enum.filter(&(&1["noun"] == "chat"))
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert chat_ids == Enum.sort(@chat_commands),
             "chat verb set drifted; got: #{inspect(chat_ids)}"

      # The SSE events route is a builtin carve-out — never a manifest verb.
      refute Enum.any?(manifest["commands"], &(&1["id"] == "chat.events"))
    end

    test "every chat command is admin-tier (existence-hidden from anon/lower callers)",
         %{conn: conn} do
      manifest = capabilities(conn)

      for id <- @chat_commands do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} not found in manifest"

        assert cmd["auth_tier"] == "admin",
               "#{id} must be admin-tier; got: #{inspect(cmd["auth_tier"])}"

        assert cmd["source"] == "core",
               "#{id} must be a core command; got: #{inspect(cmd["source"])}"
      end
    end

    test "chat verbs map to the shipped /v1/chat routes (method + path)", %{conn: conn} do
      manifest = capabilities(conn)

      expected = %{
        "chat.create_session" => {"POST", "/v1/chat/sessions"},
        "chat.list_sessions" => {"GET", "/v1/chat/sessions"},
        "chat.get_session" => {"GET", "/v1/chat/sessions/:id"},
        "chat.update_session" => {"PATCH", "/v1/chat/sessions/:id"},
        "chat.send_message" => {"POST", "/v1/chat/sessions/:id/messages"},
        "chat.interrupt" => {"POST", "/v1/chat/sessions/:id/interrupt"},
        "chat.approve" => {"POST", "/v1/chat/sessions/:id/approval"},
        "chat.answer" => {"POST", "/v1/chat/sessions/:id/answer"},
        "chat.archive" => {"POST", "/v1/chat/sessions/:id/archive"},
        "chat.unarchive" => {"POST", "/v1/chat/sessions/:id/unarchive"},
        "chat.upload_attachment" => {"POST", "/v1/chat/sessions/:id/attachments"},
        "chat.get_attachment" => {"GET", "/v1/chat/sessions/:id/attachments/:attachment_id"}
      }

      for {id, {method, path}} <- expected do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} not found in manifest"
        assert cmd["http"]["method"] == method, "#{id} method"
        assert cmd["http"]["path_template"] == path, "#{id} path"
        # Instance-global admin (D21): no per-doc scoped mirror.
        refute Map.has_key?(cmd, "scoped_prefix"),
               "#{id} must have no scoped_prefix (D21 instance-global)"
      end
    end

    test "session-scoped chat verbs carry the `id` path arg + their body args", %{conn: conn} do
      manifest = capabilities(conn)

      get_session = find_cmd(manifest, "chat.get_session")
      assert "id" in Enum.map(get_session["args"], & &1["name"])

      send = find_cmd(manifest, "chat.send_message")
      send_args = Enum.map(send["args"], & &1["name"])
      assert "id" in send_args
      assert "content" in send_args

      approve = find_cmd(manifest, "chat.approve")
      approve_args = Enum.map(approve["args"], & &1["name"])
      assert "id" in approve_args
      assert "request_id" in approve_args
      assert "decision" in approve_args
    end

    test "chat commands are hidden from an anonymous (tier none) caller", %{conn: conn} do
      # Existence-hiding: an anon manifest must learn zero chat verb NAMES and
      # not the `chat` noun name — exactly like the other admin-only nouns.
      anon = conn |> get("/v1/capabilities") |> json_response(200)

      assert anon["auth_tier"] == "none"

      refute Enum.any?(anon["commands"], &(&1["noun"] == "chat")),
             "anon manifest leaked a chat command"

      refute Enum.any?(anon["nouns"], &(&1["name"] == "chat")),
             "anon manifest leaked the chat noun name"
    end

    # D36 CLOSED (charter D16): `chat` is an ORTHOGONAL capability, not a rank.
    # RequireChatAccess.chat_scope/1 authorizes a workspace-bound
    # `permissions: ["chat"]` Connector token at `/v1/chat/*` (resolves to
    # `{:workspace, ws}`), and tier_for_token/1 now mirrors that grant: the
    # token's base tier stays "none" (chat lifts no rank), but a `+chat`
    # capability rides alongside so project/2's chat_visible?/2 side-branch
    # projects the `chat` noun + its ten verbs — and ONLY the chat noun.
    test "a workspace token carrying only `chat` sees the chat noun WITHOUT any rank lift (D36 orthogonal)",
         %{conn: conn} do
      ws = Barkpark.TenancyFixtures.create_workspace!()
      raw_token = "chat-only-#{System.unique_integer([:positive])}"
      {:ok, _} = Barkpark.Auth.create_token(raw_token, "chat-only", "test", ["chat"], ws.id)

      manifest =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> get("/v1/capabilities")
        |> json_response(200)

      # Orthogonal, not a rank: the echoed tier stays "none" — chat grants
      # discovery of its own noun, never a doc/task rank.
      assert manifest["auth_tier"] == "none",
             "chat is orthogonal — a chat-only token must still echo base tier \"none\"; " <>
               "got: #{inspect(manifest["auth_tier"])}"

      # The whole chat noun + its ten verbs are now discoverable by their
      # own token.
      assert Enum.any?(manifest["nouns"], &(&1["name"] == "chat")),
             "chat-capability workspace token must discover the chat noun"

      chat_ids =
        manifest["commands"]
        |> Enum.filter(&(&1["noun"] == "chat"))
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert chat_ids == Enum.sort(@chat_commands),
             "chat-capability token must see exactly the ten chat verbs; got: #{inspect(chat_ids)}"

      # GUARD — chat lifts NO other noun's tier. The base tier stays "none", so
      # the chat-only token must see EXACTLY the anonymous (tier-none) noun set
      # PLUS the chat noun — nothing from a higher rank leaks in. The delta
      # against the anon baseline is precisely {"chat"}.
      anon = conn |> get("/v1/capabilities") |> json_response(200)
      anon_nouns = anon["nouns"] |> Enum.map(& &1["name"]) |> MapSet.new()
      chat_only_nouns = manifest["nouns"] |> Enum.map(& &1["name"]) |> MapSet.new()

      assert MapSet.difference(chat_only_nouns, anon_nouns) == MapSet.new(["chat"]),
             "chat capability must add ONLY the chat noun over the anon baseline; delta: " <>
               "#{inspect(MapSet.difference(chat_only_nouns, anon_nouns) |> MapSet.to_list())}"

      # And the reverse: the chat token loses none of the anon-visible nouns.
      assert MapSet.subset?(anon_nouns, chat_only_nouns),
             "chat capability must not drop any anon-visible noun"
    end

    # GUARD — the orthogonal grant is chat-ONLY: a plain [read, write] token
    # (no chat permission) still gets the whole chat noun existence-hidden.
    test "a [read, write] token (no chat permission) still gets chat stripped", %{conn: conn} do
      ws = Barkpark.TenancyFixtures.create_workspace!()
      raw_token = "rw-nochat-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Barkpark.Auth.create_token(raw_token, "rw-nochat", "test", ["read", "write"], ws.id)

      manifest =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> get("/v1/capabilities")
        |> json_response(200)

      assert manifest["auth_tier"] == "write"

      refute Enum.any?(manifest["commands"], &(&1["noun"] == "chat")),
             "a [read, write] token must not see any chat command"

      refute Enum.any?(manifest["nouns"], &(&1["name"] == "chat")),
             "a [read, write] token must not see the chat noun"
    end
  end

  describe "scoped run-secrets commands (connectors D200)" do
    # The per-workspace tier of the run-secrets store gets four DEDICATED
    # verbs whose workspace/project slugs are BAKED into path_template — NOT
    # the scoped_prefix mechanism (ctx.ScopedMirror is never set in any
    # production Go path; the flat-template+scoped_prefix shape 404s, proven
    # live on token.create / #3197). The flat secret.* entries stay the
    # instance-GLOBAL tier, byte-identical.
    @scoped_secret_expected %{
      "secret.scoped-ls" => {"GET", "/w/:workspace_slug/p/:project_slug/v1/secrets", false},
      "secret.scoped-get" =>
        {"GET", "/w/:workspace_slug/p/:project_slug/v1/secrets/:name", false},
      "secret.scoped-set" => {"PUT", "/w/:workspace_slug/p/:project_slug/v1/secrets/:name", true},
      "secret.scoped-rm" =>
        {"DELETE", "/w/:workspace_slug/p/:project_slug/v1/secrets/:name", true}
    }

    test "the four scoped verbs are scoped_admin with slugs BAKED into path_template, no scoped_prefix",
         %{conn: conn} do
      manifest = capabilities(conn)

      for {id, {method, path, writes}} <- @scoped_secret_expected do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} not found in manifest"
        assert cmd["http"]["method"] == method, "#{id} method"
        assert cmd["http"]["path_template"] == path, "#{id} path_template"
        assert cmd["auth_tier"] == "scoped_admin", "#{id} must be scoped_admin tier"
        assert cmd["writes"] == writes, "#{id} writes flag"

        refute Map.has_key?(cmd, "scoped_prefix"),
               "#{id} must NOT carry scoped_prefix (that shape is proven broken — #3197)"
      end
    end

    test "name/value args ride the scoped verbs exactly like their flat siblings", %{conn: conn} do
      manifest = capabilities(conn)

      assert Enum.map(find_cmd(manifest, "secret.scoped-get")["args"], & &1["name"]) == ["name"]
      assert Enum.map(find_cmd(manifest, "secret.scoped-rm")["args"], & &1["name"]) == ["name"]

      set_args = Enum.map(find_cmd(manifest, "secret.scoped-set")["args"], & &1["name"])
      assert set_args == ["name", "value"]

      ls = find_cmd(manifest, "secret.scoped-ls")
      assert ls["args"] == []
    end

    test "the FLAT secret.* entries stay byte-identical global-tier admin", %{conn: conn} do
      manifest = capabilities(conn)

      flat_expected = %{
        "secret.ls" => {"GET", "/v1/secrets", false},
        "secret.get" => {"GET", "/v1/secrets/:name", false},
        "secret.set" => {"PUT", "/v1/secrets/:name", true},
        "secret.rm" => {"DELETE", "/v1/secrets/:name", true}
      }

      for {id, {method, path, writes}} <- flat_expected do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} not found in manifest"
        assert cmd["http"]["method"] == method, "#{id} method"
        assert cmd["http"]["path_template"] == path, "#{id} path_template drifted"
        assert cmd["auth_tier"] == "admin", "#{id} must STAY blanket admin (global tier)"
        assert cmd["writes"] == writes, "#{id} writes flag"
        refute Map.has_key?(cmd, "scoped_prefix"), "#{id} must not grow a scoped_prefix"
      end
    end

    test "the scoped route the templates point at exists (not a route-miss 404)", %{conn: conn} do
      # Grounds path_template against the real router: an ANONYMOUS call into
      # the scoped block hits the membership gate (401/403/404-not_found from
      # ResolveWorkspace on an unknown slug) — never a bare NoRouteError. The
      # full auth/tenant matrix lives in scoped_secret_controller_test.exs.
      resp =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/w/no-such-workspace/p/default/v1/secrets")

      assert resp.status in [401, 403, 404]
      assert %{"error" => %{"code" => _}} = Jason.decode!(resp.resp_body)
    end
  end

  describe "server.base_url derives from the caller's request Host (D4 server-side)" do
    # A custom instance hostname and the canonical FQDN each dial the same
    # instance behind Caddy; the manifest must echo the host the caller
    # ACTUALLY reached, not the frozen boot-time PHX_HOST scalar — so the CLI
    # records one instance with alias URLs, never a phantom "-2" second server.
    @server_keys ~w(api_version base_url min_cli name version)

    test "base_url reflects a custom Host + x-forwarded-proto:https", %{conn: conn} do
      # conn.host is set directly: Plug rejects put_req_header("host", …), and
      # the controller reads conn.host (Caddy preserves it; no x-forwarded-host).
      manifest =
        %{conn | host: "custom.example"}
        |> put_req_header("x-forwarded-proto", "https")
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/capabilities")
        |> json_response(200)

      server = manifest["server"]

      assert server["base_url"] == "https://custom.example",
             "base_url must derive from the request Host, got: #{inspect(server["base_url"])}"

      # base_url MUST stay a URL string (run.go isProd() substring-matches it).
      assert is_binary(server["base_url"])
    end

    test "the server envelope keeps EXACTLY its current keys — no field added", %{conn: conn} do
      # additionalProperties:false + Go DisallowUnknownFields: a NEW server key
      # is a whole-CLI parse outage for every older bp. VALUE-only override.
      manifest =
        %{conn | host: "other.example"}
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/capabilities")
        |> json_response(200)

      assert manifest["server"] |> Map.keys() |> Enum.sort() == @server_keys,
             "server envelope keys drifted: #{inspect(Map.keys(manifest["server"]))}"
    end
  end

  describe "command-level `views` descriptor (wave axi-brief-views, ?views=1 opt-in)" do
    # The commands that support the brief/full projection.
    @views_commands ~w(task.ready task.prime search.query)
    @frozen_views %{
      "supported" => ["brief", "full"],
      "default" => "full",
      "default_for_agents" => "brief"
    }

    # Opt-in by contract, exactly like ?build=1: released bp binaries
    # strict-decode the manifest with DisallowUnknownFields, which recurses
    # into each Command — so the DEFAULT response must NEVER grow a new
    # command-level key. ?views=1 is the escape hatch new clients use.
    test "default manifest declares NO `views` key on ANY command (old-CLI compatibility)",
         %{conn: conn} do
      manifest = capabilities(conn)

      leaked =
        manifest["commands"]
        |> Enum.filter(&Map.has_key?(&1, "views"))
        |> Enum.map(& &1["id"])

      assert leaked == [],
             "default manifest leaked a command-level `views` key on: #{inspect(leaked)} — " <>
               "it must be withheld unless ?views=1 is sent"
    end

    test "?views=1 declares the frozen `views` descriptor on exactly the three brief-capable commands",
         %{conn: conn} do
      manifest =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/capabilities?views=1")
        |> json_response(200)

      for id <- @views_commands do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} not found in manifest"

        assert cmd["views"] == @frozen_views,
               "#{id} views descriptor drifted from the frozen shape; got: #{inspect(cmd["views"])}"
      end

      # No OTHER command grows a views key — the three are the whole set.
      declaring =
        manifest["commands"]
        |> Enum.filter(&Map.has_key?(&1, "views"))
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert declaring == Enum.sort(@views_commands),
             "views key appeared on unexpected commands: #{inspect(declaring)}"
    end

    test "task.get NEVER declares `views` — it is the full-only escape hatch", %{conn: conn} do
      # Both with and without the opt-in, task.get must stay views-free.
      default = capabilities(conn)

      opted =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/capabilities?views=1")
        |> json_response(200)

      for manifest <- [default, opted] do
        cmd = find_cmd(manifest, "task.get")
        assert cmd != nil, "task.get not found in manifest"
        refute Map.has_key?(cmd, "views"), "task.get must never declare a views key"
      end
    end

    test "views and non-views bodies get DISTINCT etags (no 304 cross-contamination)",
         %{conn: conn} do
      plain = caps_conn(conn)
      with_views = caps_conn(conn, "?views=1")

      plain_etag = plain |> get_resp_header("etag") |> List.first()
      views_etag = with_views |> get_resp_header("etag") |> List.first()

      assert is_binary(plain_etag) and plain_etag != ""
      assert is_binary(views_etag) and views_etag != ""

      assert plain_etag != views_etag,
             "views and non-views manifests must have distinct etags (content-addressed body)"

      # The body echoes the same etag the header carries.
      assert json_response(plain, 200)["etag"] == plain_etag
      assert json_response(with_views, 200)["etag"] == views_etag
    end

    test "manifest.schema.json wires `views` as an ADDITIVE optional command-level $def", %{
      conn: conn
    } do
      # The CLI manifest schema is JSON-Schema draft 2020-12, which the pinned
      # ex_json_schema (draft 4/6/7 only) cannot resolve — so this grounds the
      # contract STRUCTURALLY: the additive `views` $def exists with the frozen
      # required keys, the `command` object references it as a property, and it
      # is NOT in the command required[] (so a views-ABSENT manifest still
      # validates while a views-PRESENT one is modeled).
      schema_path =
        Path.expand(Path.join([File.cwd!(), "..", "docs", "cli", "manifest.schema.json"]))

      schema = schema_path |> File.read!() |> Jason.decode!()

      views_def = get_in(schema, ["$defs", "views"])
      assert is_map(views_def), "manifest.schema.json is missing the $defs.views definition"
      assert views_def["additionalProperties"] == false, "views $def must be strict"

      assert Enum.sort(views_def["required"]) == ["default", "default_for_agents", "supported"],
             "views $def required keys drifted: #{inspect(views_def["required"])}"

      command = get_in(schema, ["$defs", "command"])

      assert get_in(command, ["properties", "views", "$ref"]) == "#/$defs/views",
             "command object must reference #/$defs/views as a property"

      refute "views" in command["required"],
             "`views` must NOT be in command.required[] — it is opt-in additive"

      # Runtime cross-check: a views-PRESENT command matches the $def's frozen
      # required-key set exactly (strict additionalProperties:false).
      with_views =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/capabilities?views=1")
        |> json_response(200)

      views = find_cmd(with_views, "task.ready")["views"]
      assert Enum.sort(Map.keys(views)) == ["default", "default_for_agents", "supported"]
    end

    test "an If-None-Match with the NON-views etag does NOT 304 the ?views=1 body", %{conn: conn} do
      plain_etag = caps_conn(conn) |> get_resp_header("etag") |> List.first()

      # Presenting the plain etag against the views request must re-render (200),
      # never short-circuit to 304 — the bodies differ.
      resp =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> put_req_header("if-none-match", plain_etag)
        |> get("/v1/capabilities?views=1")

      assert resp.status == 200,
             "the non-views etag must not 304 the views body; got status #{resp.status}"
    end
  end

  describe "root `chat` discovery block (charter D27, ?chat=1 opt-in)" do
    # Opt-in by contract, exactly like ?build=1/?views=1: released bp binaries
    # strict-decode the manifest ROOT with DisallowUnknownFields, so the
    # DEFAULT response must NEVER grow a new root key. There is no
    # whole-manifest root-key freeze elsewhere — these negative tests ARE the
    # guard.
    test "default manifest carries NO root chat key — byte-identical incl etag",
         %{conn: conn} do
      plain = caps_conn(conn)
      body = json_response(plain, 200)

      refute Map.has_key?(body, "chat"),
             "default manifest leaked the root chat key — it must be withheld unless ?chat=1"

      # The default body and its etag must be exactly what a chat-oblivious
      # request gets — the chat gate must not perturb the ungated pipeline.
      # etag is content-addressed off the final map (generated_at excluded), so
      # etag equality IS body identity minus the per-request timestamp.
      twin = caps_conn(build_conn())
      twin_body = json_response(twin, 200)

      assert Map.delete(body, "generated_at") == Map.delete(twin_body, "generated_at")
      assert get_resp_header(plain, "etag") == get_resp_header(twin, "etag")
    end

    test "?chat=1 carries claude caps and empty-array codex (the degrade signal)",
         %{conn: conn} do
      body = caps_conn(conn, "?chat=1") |> json_response(200)

      assert %{"providers" => providers} = body["chat"]

      # claude: the transport-ACCEPTED vocabulary — Runtime.capabilities/1
      # minus the danger mode (bypassPermissions is categorically rejected on
      # /v1/chat, D22; advertising it would bait a guaranteed 400).
      claude = providers["claude"]
      caps = Barkpark.StudioChat.Runtime.capabilities("claude")

      assert claude["modes"] == caps.modes -- [caps.danger_mode]
      refute "bypassPermissions" in claude["modes"]
      assert claude["models"] == caps.models
      assert claude["efforts"] == caps.efforts

      # codex ships all-empty TODAY — pickers must degrade, never invent.
      assert providers["codex"] == %{"modes" => [], "models" => [], "efforts" => []}
    end

    test "anonymous ?chat=1 gets nothing (tier none — mirrors the build gate)", %{conn: conn} do
      body =
        conn
        |> get("/v1/capabilities?chat=1")
        |> json_response(200)

      assert body["auth_tier"] == "none"

      refute Map.has_key?(body, "chat"),
             "an anonymous caller must not discover the chat surface via ?chat=1"
    end

    test "chat and non-chat bodies get DISTINCT etags; the plain etag does NOT 304 ?chat=1",
         %{conn: conn} do
      plain = caps_conn(conn)
      with_chat = caps_conn(build_conn(), "?chat=1")

      plain_etag = plain |> get_resp_header("etag") |> List.first()
      chat_etag = with_chat |> get_resp_header("etag") |> List.first()

      assert is_binary(plain_etag) and plain_etag != ""
      assert is_binary(chat_etag) and chat_etag != ""

      assert plain_etag != chat_etag,
             "chat and non-chat manifests must have distinct etags (maybe_gate_chat sits BEFORE etag_for)"

      # The body echoes the same etag the header carries.
      assert json_response(with_chat, 200)["etag"] == chat_etag

      # Presenting the plain etag against the chat request must re-render (200).
      resp =
        build_conn()
        |> put_req_header("authorization", "Bearer #{@token}")
        |> put_req_header("if-none-match", plain_etag)
        |> get("/v1/capabilities?chat=1")

      assert resp.status == 200,
             "the non-chat etag must not 304 the chat body; got status #{resp.status}"
    end
  end

  describe "`writes` honesty: no core mutator is advertised read-only (PDS-D302)" do
    # `writes` is the ONE side-effect signal the MCP bridge sees:
    # internal/cli/mcp_bridge.go derives `ReadOnlyHint` straight from it. It used
    # to default to `false` at the builder (`Keyword.get(opts, :writes, false)`),
    # and 16 non-GET core commands never passed it — so an MCP client was told
    # `chat.send_message` and `auth.mfa-disable` were safe read-only calls. The
    # builder now takes `Keyword.fetch!(opts, :writes)`, which can only catch a
    # MISSING bit; a wrong `false` is caught here and nowhere else.
    #
    # Deliberately anchored on the SERVED manifest, not the source: what an MCP
    # client is told is what matters.
    @previously_mislabelled ~w(
      auth.register auth.login auth.verify-email auth.request-reset auth.reset
      auth.logout auth.mfa-enroll auth.mfa-verify auth.mfa-disable
      chat.create_session chat.update_session chat.send_message chat.interrupt
      chat.approve chat.archive chat.unarchive
    )

    test "every core command whose HTTP method is not GET carries writes == true",
         %{conn: conn} do
      liars =
        capabilities(conn)["commands"]
        |> Enum.filter(&(&1["source"] == "core"))
        |> Enum.filter(&(&1["http"]["method"] != "GET"))
        |> Enum.reject(&(&1["writes"] == true))
        |> Enum.map(&{&1["id"], &1["http"]["method"], &1["writes"]})
        |> Enum.sort()

      assert liars == [],
             """
             These core commands mutate over a non-GET method but are advertised
             read-only — an MCP client reads `writes` as ReadOnlyHint and will call
             them without confirmation:

                 #{inspect(liars, pretty: true)}
             """
    end

    test "the 16 commands that shipped mislabelled are present and now honest",
         %{conn: conn} do
      commands = capabilities(conn)["commands"]

      for id <- @previously_mislabelled do
        cmd = Enum.find(commands, &(&1["id"] == id))
        assert cmd != nil, "#{id} is missing from the manifest (admin token sees every tier)"
        refute cmd["http"]["method"] == "GET", "#{id} is expected to be a non-GET mutator"

        assert cmd["writes"] == true,
               "#{id} is still advertised writes == #{inspect(cmd["writes"])}"
      end
    end

    test "a GET command still reports writes == false (the flag stayed a signal)",
         %{conn: conn} do
      cmd = find_cmd(capabilities(conn), "doc.get")

      assert cmd["http"]["method"] == "GET"
      assert cmd["writes"] == false
    end
  end

  describe "root `bpml` vocabulary block (BPML masterplan W0, ?bpml=1 opt-in)" do
    test "default manifest carries NO root bpml key", %{conn: conn} do
      body = caps_conn(conn) |> json_response(200)

      refute Map.has_key?(body, "bpml"),
             "default manifest leaked the root bpml key — it must be withheld unless ?bpml=1"
    end

    test "?bpml=1 serves the grammar with a derived digest", %{conn: conn} do
      body = caps_conn(conn, "?bpml=1") |> json_response(200)

      assert %{"blocks" => blocks, "inline" => inline, "formats" => formats, "digest" => digest} =
               body["bpml"]

      # the attribute contract agents generate types from
      assert blocks["callout"] == ["id", "tone", "title"]
      assert blocks["stat"] == ["label", "value", "denom"]
      assert blocks["paper"] == ["slug", "title"]
      # aliases ride the table — <strong> teaches nothing new
      assert inline["b"] == "strong"
      assert inline["strong"] == "strong"
      assert formats == ["json", "bpml"]
      # derived, stable, prefixed — clients echo it to detect stale types
      assert String.starts_with?(digest, "bpml-")
      assert body["bpml"]["digest"] == Barkpark.PortableDoc.Bpml.vocabulary()["digest"]
    end

    test "anonymous ?bpml=1 STILL gets the vocabulary (public format, not a capability)",
         %{conn: conn} do
      body = conn |> get("/v1/capabilities?bpml=1") |> json_response(200)

      assert body["auth_tier"] == "none"
      assert %{"digest" => "bpml-" <> _} = body["bpml"]
    end
  end

  # ── Undeclared verb families (task wb-api-capabilities-undeclared-verbs) ──
  #
  # Four live-but-unadvertised route families get core_cmd entries here. Per
  # the task's non-negotiable, every verb below is INVOKED through the real
  # router + controller — declared on the strength of an observed response,
  # never the router text alone.

  describe "share.token-* (P5 edit tokens) live routes" do
    setup do
      # `Auth.create_share_token/5` (behind POST /v1/shares/tokens) requires
      # the scope to ALREADY be a live `:edit` share for the surface — it
      # never manufactures that precondition itself. Snapshot + restore the
      # registry exactly like `share_controller_test.exs` does.
      prior_shares = Application.get_env(:barkpark, :shares)
      prior_env = Application.get_env(:barkpark, :shares_env)

      on_exit(fn ->
        restore_app_env(:shares, prior_shares)
        restore_app_env(:shares_env, prior_env)
      end)

      raw = "ucv-share-tok-admin-#{System.unique_integer([:positive])}"

      {:ok, actor} =
        Auth.create_token(raw, "ucv-share-tok-admin", "test", ["read", "write", "admin"])

      ws = create_workspace!()
      project = create_project!(ws)
      {:ok, _} = TenancyAuth.create_membership(ws.id, actor.id, "admin")
      {:ok, _} = Barkpark.Sharing.add_share("#{ws.slug}/#{project.slug}/production:docs:edit")

      junior = "ucv-share-tok-junior-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(junior, "ucv-share-tok-junior", "test", ["read", "write"])

      %{raw: raw, junior: junior, ws: ws, project: project}
    end

    test "manifest declares token-ls/token-mint/token-revoke under the `share` noun, admin tier",
         %{conn: conn} do
      manifest = capabilities(conn)

      expected = %{
        "share.token-ls" => {"GET", "/v1/shares/tokens"},
        "share.token-mint" => {"POST", "/v1/shares/tokens"},
        "share.token-revoke" => {"DELETE", "/v1/shares/tokens/:token_id"}
      }

      for {id, {method, path}} <- expected do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} missing from manifest"
        assert cmd["noun"] == "share"
        assert cmd["http"] == %{"method" => method, "path_template" => path}
        assert cmd["auth_tier"] == "admin"
      end
    end

    test "POST mints, GET lists, DELETE revokes — the real route (401 anon, 403 non-admin)",
         %{conn: conn, raw: raw, junior: junior, ws: ws, project: project} do
      scope = "#{ws.slug}/#{project.slug}/production"

      assert post(conn, "/v1/shares/tokens", %{scope: scope, surfaces: "docs"}).status == 401

      assert conn
             |> bearer(junior)
             |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
             |> Map.fetch!(:status) == 403

      mint_resp =
        conn |> bearer(raw) |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})

      assert mint_resp.status == 201

      %{"token" => raw_share_token, "share_token" => %{"id" => token_id}} =
        json_response(mint_resp, 201)

      assert is_binary(raw_share_token) and raw_share_token != ""

      ls_resp = conn |> bearer(raw) |> get("/v1/shares/tokens?scope=#{scope}")
      assert ls_resp.status == 200
      ids = ls_resp |> json_response(200) |> Map.fetch!("tokens") |> Enum.map(& &1["id"])
      assert token_id in ids

      revoke_resp = conn |> bearer(raw) |> delete("/v1/shares/tokens/#{token_id}")
      assert revoke_resp.status == 200
      assert json_response(revoke_resp, 200)["revoked"] == true
    end
  end

  describe "share.link-* (P7 item share links) live routes" do
    setup do
      raw = "ucv-share-link-admin-#{System.unique_integer([:positive])}"

      {:ok, actor} =
        Auth.create_token(raw, "ucv-share-link-admin", "test", ["read", "write", "admin"])

      ws = create_workspace!()
      project = create_project!(ws)
      {:ok, _} = TenancyAuth.create_membership(ws.id, actor.id, "admin")
      {:ok, media} = create_media_file_in!(ws, project)

      %{raw: raw, ws: ws, project: project, media: media}
    end

    test "manifest declares link-ls/link-mint/link-revoke under the `share` noun, admin tier",
         %{conn: conn} do
      manifest = capabilities(conn)

      expected = %{
        "share.link-ls" => {"GET", "/v1/shares/links"},
        "share.link-mint" => {"POST", "/v1/shares/links"},
        "share.link-revoke" => {"DELETE", "/v1/shares/links/:id"}
      }

      for {id, {method, path}} <- expected do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} missing from manifest"
        assert cmd["noun"] == "share"
        assert cmd["http"] == %{"method" => method, "path_template" => path}
        assert cmd["auth_tier"] == "admin"
      end
    end

    test "POST mints a media link, GET lists it, DELETE revokes it — the real route",
         %{conn: conn, raw: raw, ws: ws, project: project, media: media} do
      scope = "#{ws.slug}/#{project.slug}/production"

      mint_resp =
        conn
        |> bearer(raw)
        |> post("/v1/shares/links", %{scope: scope, kind: "media", ref_id: media.id})

      assert mint_resp.status == 201
      %{"token" => raw_link_token, "link" => %{"id" => link_id}} = json_response(mint_resp, 201)
      assert is_binary(raw_link_token) and raw_link_token != ""

      ls_resp =
        conn
        |> bearer(raw)
        |> get("/v1/shares/links?scope=#{scope}&kind=media&ref_id=#{media.id}")

      assert ls_resp.status == 200
      ids = ls_resp |> json_response(200) |> Map.fetch!("links") |> Enum.map(& &1["id"])
      assert link_id in ids

      revoke_resp = conn |> bearer(raw) |> delete("/v1/shares/links/#{link_id}")
      assert revoke_resp.status == 200
      assert json_response(revoke_resp, 200)["revoked"] == true
    end
  end

  describe "app_token.* (mobile app-token exchange) live routes" do
    setup do
      admin = "ucv-appt-admin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(admin, "ucv-appt-admin", "test", ["read", "write", "admin"])
      reader = "ucv-appt-reader-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(reader, "ucv-appt-reader", "test", ["read"])

      %{admin: admin, reader: reader}
    end

    test "manifest: app_token is a noun distinct from token, with tiers from the CONTROLLER gate",
         %{conn: conn} do
      manifest = capabilities(conn)
      assert Enum.any?(manifest["nouns"], &(&1["name"] == "app_token"))

      # `token` keeps serving /v1/tokens, untouched — the two nouns never fold.
      assert find_cmd(manifest, "token.ls")["http"]["path_template"] == "/v1/tokens"

      expected = %{
        "app_token.create" => {"POST", "/v1/auth/app-tokens", "admin"},
        "app_token.ls" => {"GET", "/v1/auth/app-tokens", "admin"},
        "app_token.revoke" => {"DELETE", "/v1/auth/app-tokens", "admin"},
        "app_token.revoke-by-id" => {"DELETE", "/v1/auth/app-tokens/:id", "admin"},
        # The self-revoke exception: reachable by a read-permission bearer
        # (the controller only REFUSES an admin bearer), so it is the one
        # verb in this family that must NOT be existence-hidden from "read".
        "app_token.revoke-current" => {"DELETE", "/v1/auth/app-tokens/current", "read"}
      }

      for {id, {method, path, tier}} <- expected do
        cmd = find_cmd(manifest, id)
        assert cmd != nil, "#{id} missing from manifest"
        assert cmd["noun"] == "app_token"
        assert cmd["http"] == %{"method" => method, "path_template" => path}

        assert cmd["auth_tier"] == tier,
               "#{id} auth_tier should be #{tier}, got #{cmd["auth_tier"]}"
      end
    end

    test "POST is controller-gated (401 non-admin, not the :require_token pipeline)",
         %{conn: conn, admin: admin, reader: reader} do
      email = "ucv-app-#{System.unique_integer([:positive])}@example.com"

      refused = conn |> bearer(reader) |> post("/v1/auth/app-tokens", %{"email" => email})

      assert refused.status == 401,
             "non-admin bearer must get the generic unauthorized from the controller's " <>
               "admin check, not a free pass from :require_token alone"

      minted = conn |> bearer(admin) |> post("/v1/auth/app-tokens", %{"email" => email})
      assert minted.status == 201
      body = json_response(minted, 201)
      assert is_binary(body["token"]) and body["token"] != ""
      assert body["permissions"] == ["read", "write", "chat"]
    end

    test "GET lists it, then DELETE .../current self-revokes with NO admin bearer",
         %{conn: conn, admin: admin} do
      email = "ucv-app2-#{System.unique_integer([:positive])}@example.com"

      %{"token" => raw_app_token} =
        conn
        |> bearer(admin)
        |> post("/v1/auth/app-tokens", %{"email" => email})
        |> json_response(201)

      ls = conn |> bearer(admin) |> get("/v1/auth/app-tokens")
      assert ls.status == 200

      # `label_redacted` was `true` here until `task-aa07355fa8a53355` scoped
      # the sweep to the bearer's admin workspaces; with the rows confined
      # there is nothing left to withhold, so the flag is a kept-for-wire,
      # always-`false` envelope field. The key's PRESENCE is the contract this
      # manifest test cares about.
      assert %{"tokens" => _, "label_redacted" => false} = json_response(ls, 200)

      # Self-revoke: the MINTED token is its own bearer — no admin permission
      # anywhere in this call.
      self_revoke = conn |> bearer(raw_app_token) |> delete("/v1/auth/app-tokens/current")
      assert self_revoke.status == 200
      assert json_response(self_revoke, 200)["revoked"] == true

      # Fail-closed proof: the same bearer is rejected afterwards.
      after_revoke = conn |> bearer(raw_app_token) |> get("/v1/auth/app-tokens")
      assert after_revoke.status == 401
    end

    test "DELETE body {token:} and DELETE /:id each revoke a real row",
         %{conn: conn, admin: admin} do
      email_a = "ucv-app3-#{System.unique_integer([:positive])}@example.com"
      email_b = "ucv-app4-#{System.unique_integer([:positive])}@example.com"

      %{"token" => raw_a} =
        conn
        |> bearer(admin)
        |> post("/v1/auth/app-tokens", %{"email" => email_a})
        |> json_response(201)

      by_token = conn |> bearer(admin) |> delete("/v1/auth/app-tokens", %{"token" => raw_a})
      assert by_token.status == 200
      assert json_response(by_token, 200)["revoked"] == true

      %{"token" => _raw_b} =
        conn
        |> bearer(admin)
        |> post("/v1/auth/app-tokens", %{"email" => email_b})
        |> json_response(201)

      [row] =
        conn
        |> bearer(admin)
        |> get("/v1/auth/app-tokens?email=#{email_b}")
        |> json_response(200)
        |> Map.fetch!("tokens")

      by_id = conn |> bearer(admin) |> delete("/v1/auth/app-tokens/#{row["id"]}")
      assert by_id.status == 200
      assert json_response(by_id, 200)["revoked"] == true
    end
  end

  describe "fleet_support_token.* (Personal Dev Fleet) live routes" do
    setup do
      admin = "ucv-fst-admin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(admin, "ucv-fst-admin", "test", ["read", "write", "admin"])
      junior = "ucv-fst-junior-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(junior, "ucv-fst-junior", "test", ["read", "write"])

      %{admin: admin, junior: junior}
    end

    test "manifest declares fleet_support_token.create/revoke as admin tier", %{conn: conn} do
      manifest = capabilities(conn)
      assert Enum.any?(manifest["nouns"], &(&1["name"] == "fleet_support_token"))

      create_cmd = find_cmd(manifest, "fleet_support_token.create")

      assert create_cmd["http"] == %{
               "method" => "POST",
               "path_template" => "/v1/fleet/support-tokens"
             }

      assert create_cmd["auth_tier"] == "admin"
      assert create_cmd["writes"] == true

      revoke_cmd = find_cmd(manifest, "fleet_support_token.revoke")

      assert revoke_cmd["http"] == %{
               "method" => "DELETE",
               "path_template" => "/v1/fleet/support-tokens/:token_id"
             }

      assert revoke_cmd["auth_tier"] == "admin"
    end

    test "POST mints a write-capable token (403 non-admin), DELETE revokes it for real",
         %{conn: conn, admin: admin, junior: junior} do
      refused = conn |> bearer(junior) |> post("/v1/fleet/support-tokens", %{"name" => "ucv"})
      assert refused.status == 403

      minted = conn |> bearer(admin) |> post("/v1/fleet/support-tokens", %{"name" => "ucv"})
      assert minted.status == 201
      body = json_response(minted, 201)
      assert is_binary(body["token"]) and body["token"] != ""
      token_id = body["token_id"]

      revoke_resp = conn |> bearer(admin) |> delete("/v1/fleet/support-tokens/#{token_id}")
      assert revoke_resp.status == 200
      assert json_response(revoke_resp, 200)["revoked"] == true

      # Idempotent-safe 200 (re-stamps the same revoked_at row), never a crash,
      # on a second revoke of the same row.
      second = conn |> bearer(admin) |> delete("/v1/fleet/support-tokens/#{token_id}")
      assert second.status == 200
    end
  end

  describe "incident.* (status-page incidents) live routes" do
    setup do
      admin = "ucv-incident-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(admin, "ucv-incident-admin", "test", ["read", "write", "admin"])

      junior = "ucv-incident-junior-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(junior, "ucv-incident-junior", "test", ["read", "write"])

      %{admin: admin, junior: junior}
    end

    test "manifest declares incident.create/resolve as admin tier over /v1/status/incidents",
         %{conn: conn} do
      manifest = capabilities(conn)
      assert Enum.any?(manifest["nouns"], &(&1["name"] == "incident"))

      create_cmd = find_cmd(manifest, "incident.create")

      assert create_cmd["http"] == %{
               "method" => "POST",
               "path_template" => "/v1/status/incidents"
             }

      assert create_cmd["auth_tier"] == "admin"

      resolve_cmd = find_cmd(manifest, "incident.resolve")

      assert resolve_cmd["http"] == %{
               "method" => "POST",
               "path_template" => "/v1/status/incidents/:id/resolve"
             }

      assert resolve_cmd["auth_tier"] == "admin"
    end

    test "POST creates a real incident (403 non-admin), resolve transitions it",
         %{conn: conn, admin: admin, junior: junior} do
      attrs = %{
        "title" => "ucv test incident",
        "impact" => "minor",
        "status" => "investigating",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      refused = conn |> bearer(junior) |> post("/v1/status/incidents", attrs)
      assert refused.status == 403

      created = conn |> bearer(admin) |> post("/v1/status/incidents", attrs)
      assert created.status == 201

      %{"incident" => %{"id" => id, "status" => "investigating", "resolved_at" => nil}} =
        json_response(created, 201)

      resolved = conn |> bearer(admin) |> post("/v1/status/incidents/#{id}/resolve", %{})
      assert resolved.status == 200

      %{"incident" => %{"status" => "resolved", "resolved_at" => resolved_at}} =
        json_response(resolved, 200)

      assert resolved_at != nil
    end
  end
end
