defmodule BarkparkWeb.SchemaDatasetHashTenancyTest do
  @moduledoc """
  task-803991319aa64189 — `datasetSchemaHash` was computed against the seeded
  DEFAULT workspace for every tenant.

  ## The mechanism

  `Content.Schema.list_schemas_for_sdk/2` threaded the caller's scope into
  `list_schemas(dataset, opts)` and then, on the very next line, called the
  arity-1 `schema_hash_for_dataset(dataset)` — dropping the `opts` it had just
  used. With empty opts `resolve_read_dataset_id/2` falls through to
  `read_default_project_id/1` (write_scope.ex), so `scope_to_dataset/3` filtered
  on the DEFAULT project's `production` `dataset_id`. The `schemas` array was
  correctly the caller's (it goes through the workspace/project filter in
  `list_schemas/2`); only the hash crossed the tenant boundary.

  Two consequences, both measured below:

    1. Cross-tenant change ORACLE — the value flipped whenever the Default
       workspace touched a schema, observable by every other tenant's admin.
    2. Silent correctness LOSS — the value was INVARIANT to the caller's own
       schema edits, so the codegen staleness banner
       (`js/packages/codegen/src/generate.ts`) never moved for a non-Default
       tenant.

  ## Why the assertions are on the HASH, not the status

  The endpoint answered 200 with a well-formed 16-hex hash the whole time, so a
  status/shape assertion is vacuous (`schema_envelope_test.exs` already pins the
  shape and stayed green throughout). The discriminant is which workspace's
  edits MOVE the value.

  On origin/main both hash tests RED with the assertions exactly INVERTED: the
  hash ignores B's schemas and tracks Default's.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures,
    only: [create_workspace!: 0, create_project!: 1, ensure_default_scope!: 0]

  alias Barkpark.{Auth, Content}

  # The dataset STRING is deliberately the SAME in both workspaces — that shared
  # slug is the whole conflation vector. Isolation must come from the resolved
  # `dataset_id`, never from the leaf name.
  @dataset "production"

  setup %{conn: conn} do
    # The Default workspace must EXIST for the defect to manifest at all: with
    # nothing seeded at slug "default", `read_default_project_id/1` returns nil
    # and the buggy read silently degrades to the legacy STRING filter.
    {default_ws, default_project} = ensure_default_scope!()
    default_scope = [workspace_id: default_ws.id, project_id: default_project.id]

    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    # DIFFERENT schema counts on the two sides, so a hash taken from the wrong
    # one cannot coincide with the right one by arithmetic accident.
    seed_schema!(default_scope, "default")
    seed_schema!(default_scope, "default")
    seed_schema!(default_scope, "default")
    b_first = seed_schema!(scope_b, "b")

    # A workspace-B-bound admin token. `Auth.create_token/5` with a workspace_id
    # also writes the owner/admin MEMBERSHIP row that `:scoped_admin`'s
    # `RequireWorkspaceRole` reads, so this is a legitimate admin OF B.
    raw = "schema-hash-opts-b-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        raw,
        "schema-hash-opts admin of B",
        @dataset,
        ["read", "write", "admin"],
        ws_b.id
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

    %{
      conn: conn,
      ws_b: ws_b,
      proj_b: proj_b,
      scope_b: scope_b,
      default_scope: default_scope,
      b_first: b_first
    }
  end

  # Unique names: the test DB is shared, and a fixed name would collide with a
  # sibling run (and with the seeded catalog) on the (name, dataset_id) pair.
  defp seed_schema!(scope, prefix) do
    name = "#{prefix}_type_#{System.unique_integer([:positive])}"

    {:ok, schema} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    schema.name
  end

  # The FLAT route (task-09ea9f28764a8790). No /w/:ws/p/:project in the path:
  # `DeriveWorkspaceFromToken` resolves the workspace from the BEARER TOKEN, and
  # `AssignDefaultScope` deliberately declines to pair a non-Default workspace
  # with the Default project — so the opts carry a `workspace_id` with NO
  # `project_id`, `resolve_read_dataset_id/2` returns nil, and the dataset filter
  # degrades to the bare `dataset == "production"` STRING. That is the exact
  # configuration in which the digest used to span every tenant.
  defp read_flat_hash(conn) do
    body =
      conn
      |> get("/v1/schemas/#{@dataset}")
      |> json_response(200)

    assert body["datasetSchemaHash"] =~ ~r/^[0-9a-f]{16}$/
    body["datasetSchemaHash"]
  end

  defp read_hash(conn, ws_b, proj_b) do
    body =
      conn
      |> get("/w/#{ws_b.slug}/p/#{proj_b.slug}/v1/schemas/#{@dataset}")
      |> json_response(200)

    assert body["datasetSchemaHash"] =~ ~r/^[0-9a-f]{16}$/
    body
  end

  test "datasetSchemaHash MOVES when the CALLER's own schemas change",
       %{conn: conn, ws_b: ws_b, proj_b: proj_b, scope_b: scope_b} do
    before = read_hash(conn, ws_b, proj_b)["datasetSchemaHash"]

    seed_schema!(scope_b, "b")

    after_own = read_hash(conn, ws_b, proj_b)["datasetSchemaHash"]

    refute after_own == before,
           "datasetSchemaHash did not move after workspace B added a schema to its OWN " <>
             "`#{@dataset}` — the hash is not derived from the caller's scope, so SDK " <>
             "codegen staleness detection is inert for every non-Default tenant " <>
             "(list_schemas_for_sdk dropped `opts` on the schema_hash_for_dataset call)"
  end

  test "datasetSchemaHash is DEAF to the Default workspace's schema changes",
       %{conn: conn, ws_b: ws_b, proj_b: proj_b, default_scope: default_scope} do
    before = read_hash(conn, ws_b, proj_b)["datasetSchemaHash"]

    # A change ONLY in the Default workspace. B touched nothing.
    seed_schema!(default_scope, "default")

    after_foreign = read_hash(conn, ws_b, proj_b)["datasetSchemaHash"]

    assert after_foreign == before,
           "datasetSchemaHash changed for workspace B when only the DEFAULT workspace " <>
             "added a schema — the value is a cross-tenant change ORACLE: any tenant's " <>
             "admin can watch the Default workspace's schema count and mtime move"
  end

  test "control: the `schemas` array was already correctly B's only",
       %{conn: conn, ws_b: ws_b, proj_b: proj_b, b_first: b_first} do
    names = read_hash(conn, ws_b, proj_b)["schemas"] |> Enum.map(& &1["name"])

    assert b_first in names

    refute Enum.any?(names, &String.starts_with?(&1, "default_type_")),
           "the schemas array leaked a Default-workspace type — this control must stay " <>
             "GREEN on both sides of the fix; a red here means the fence moved"
  end

  describe "FLAT /v1/schemas/:dataset — the workspace-only scope" do
    setup do
      # A THIRD tenant, so the proof is not Default-specific: the old digest was
      # a bare `dataset == "production"` count, which any workspace could move.
      ws_c = create_workspace!()
      proj_c = create_project!(ws_c)
      scope_c = [workspace_id: ws_c.id, project_id: proj_c.id]
      seed_schema!(scope_c, "c")

      %{scope_c: scope_c}
    end

    test "hash MOVES when B adds a schema", %{conn: conn, scope_b: scope_b} do
      before = read_flat_hash(conn)

      seed_schema!(scope_b, "b")

      refute read_flat_hash(conn) == before,
             "the flat datasetSchemaHash did not move after workspace B added a schema " <>
               "to its OWN `#{@dataset}` — the caller's own edits must be exactly what " <>
               "moves this value"
    end

    test "hash is DEAF to a DEFAULT-workspace-only edit",
         %{conn: conn, default_scope: default_scope} do
      before = read_flat_hash(conn)

      seed_schema!(default_scope, "default")

      assert read_flat_hash(conn) == before,
             "the flat datasetSchemaHash moved for workspace B when only the DEFAULT " <>
               "workspace added a schema — schema_hash_for_dataset/2 applied only the " <>
               "dataset filter, which degrades to the bare `dataset` STRING on the flat " <>
               "path, so the digest spans every workspace's same-named dataset"
    end

    test "hash is DEAF to a THIRD workspace's edit (the oracle is not Default-specific)",
         %{conn: conn, scope_c: scope_c} do
      before = read_flat_hash(conn)

      seed_schema!(scope_c, "c")

      assert read_flat_hash(conn) == before,
             "the flat datasetSchemaHash moved for workspace B when unrelated workspace C " <>
               "added a schema — any tenant could watch any other tenant's schema count " <>
               "and mtime move"
    end

    test "control: the flat `schemas` array is B's only, on both sides of the fix",
         %{conn: conn, b_first: b_first} do
      names =
        conn
        |> get("/v1/schemas/#{@dataset}")
        |> json_response(200)
        |> Map.get("schemas")
        |> Enum.map(& &1["name"])

      assert b_first in names

      refute Enum.any?(
               names,
               &(String.starts_with?(&1, "default_type_") or String.starts_with?(&1, "c_type_"))
             ),
             "the flat schemas array leaked another workspace's type — list_schemas/2's " <>
               "confinement is the thing the hash is being aligned WITH, so a red here " <>
               "invalidates the premise of the fix"
    end
  end
end
