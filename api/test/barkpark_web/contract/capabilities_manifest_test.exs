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
end
