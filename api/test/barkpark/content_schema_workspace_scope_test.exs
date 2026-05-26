defmodule Barkpark.ContentSchemaWorkspaceScopeTest do
  @moduledoc """
  barkpark-oewv: cross-workspace schema-definition visibility isolation.

  Schema definitions carry the content MODEL — field shapes, `visibility`
  flags (public/private), CORS allow-lists. A read scoped to workspace B that
  surfaced workspace A's schema would leak A's tenant content model. The read
  paths (`list_schemas/3`, `get_schema/3`, `list_schemas_for_sdk/3`) all thread
  `workspace_id`/`project_id` through `scope_to_workspace_or_global/3`; the
  write path (`upsert_schema/3` → `put_scope_attrs`) STAMPS `workspace_id` on
  the row. This proves the boundary holds in BOTH directions:

    * A schema upserted under workspace A is INVISIBLE to a read scoped to B
      (`list_schemas`, `get_schema`, `list_schemas_for_sdk`).
    * The SAME read scoped to A still surfaces A's schema (the never-worse /
      legit direction — strict scoping must not drop a tenant's own row).

  The dataset STRING (`"test"`) is deliberately SHARED across both workspaces
  so isolation must come from `workspace_id`, not the dataset leaf — a
  bare-dataset read would conflate the two.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "test"

  # Two workspaces, each with a project, sharing the dataset STRING "test".
  # Workspace A owns a single schema named "a_only"; workspace B owns none of
  # A's schemas (it gets its own "b_only" so the SDK/list reads have a non-empty
  # B catalog to assert against without ever crossing into A's "a_only").
  defp two_workspaces_with_schemas do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "a_only", "title" => "A Only", "visibility" => "private", "fields" => []},
        @ds,
        scope_a
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "b_only", "title" => "B Only", "visibility" => "public", "fields" => []},
        @ds,
        scope_b
      )

    {scope_a, scope_b}
  end

  test "list_schemas scoped to B does NOT include workspace A's schema (by name)" do
    {scope_a, scope_b} = two_workspaces_with_schemas()

    a_names = Content.list_schemas(@ds, scope_a) |> Enum.map(& &1.name)
    b_names = Content.list_schemas(@ds, scope_b) |> Enum.map(& &1.name)

    # LEGIT direction: A's own scoped read surfaces "a_only" (strict scoping
    # must not drop a tenant's own row).
    assert "a_only" in a_names,
           "expected A's read to surface its own schema \"a_only\", got #{inspect(a_names)}"

    # Leak guard: B must never see A's "a_only" — and B does see its own.
    refute "a_only" in b_names,
           "CROSS-WORKSPACE LEAK: \"a_only\" (created in workspace A) was returned under " <>
             "workspace B's scope — got #{inspect(b_names)}"

    assert "b_only" in b_names
    refute "b_only" in a_names
  end

  test "get_schema scoped to B returns {:error, :not_found} for workspace A's schema" do
    {scope_a, scope_b} = two_workspaces_with_schemas()

    # LEGIT: A resolves its own schema by name.
    assert {:ok, %{name: "a_only", visibility: "private"}} =
             Content.get_schema("a_only", @ds, scope_a)

    # Leak guard: B asking for A's schema name gets not_found — never A's row.
    assert {:error, :not_found} = Content.get_schema("a_only", @ds, scope_b)

    # And the mirror: B resolves its own, A cannot see B's.
    assert {:ok, %{name: "b_only"}} = Content.get_schema("b_only", @ds, scope_b)
    assert {:error, :not_found} = Content.get_schema("b_only", @ds, scope_a)
  end

  test "list_schemas_for_sdk scoped to B excludes workspace A's schema (by name)" do
    {scope_a, scope_b} = two_workspaces_with_schemas()

    a_sdk_names = Content.list_schemas_for_sdk(@ds, scope_a).schemas |> Enum.map(& &1.name)
    b_sdk_names = Content.list_schemas_for_sdk(@ds, scope_b).schemas |> Enum.map(& &1.name)

    # LEGIT: A's SDK envelope carries its own schema.
    assert "a_only" in a_sdk_names,
           "expected A's SDK list to surface \"a_only\", got #{inspect(a_sdk_names)}"

    # Leak guard: B's SDK envelope must not carry A's schema.
    refute "a_only" in b_sdk_names,
           "CROSS-WORKSPACE LEAK (SDK): \"a_only\" leaked into workspace B's SDK schema list — " <>
             "got #{inspect(b_sdk_names)}"

    assert "b_only" in b_sdk_names
    refute "b_only" in a_sdk_names
  end

  test "a workspace's own schema survives strict scoping (never-worse: scoped reads do not vanish)" do
    {scope_a, _scope_b} = two_workspaces_with_schemas()

    # The strict workspace filter must not make a legitimately-stamped row vanish
    # under its OWN scope. All three read paths agree A sees "a_only".
    assert "a_only" in (Content.list_schemas(@ds, scope_a) |> Enum.map(& &1.name))
    assert {:ok, %{name: "a_only"}} = Content.get_schema("a_only", @ds, scope_a)
    assert "a_only" in (Content.list_schemas_for_sdk(@ds, scope_a).schemas |> Enum.map(& &1.name))
  end

  # barkpark-su54: schema_public?/3 is the PUBLIC-READ GATE consulted before the
  # row read (query_controller: list_documents / get_document). It MUST resolve
  # the schema's `visibility` in the SAME tenant the row read resolves to. The
  # pre-fix 2-arity form passed NO opts to get_schema → workspace_id=nil and
  # `resolve_read_dataset_id` fell back to `read_default_project_id()`, so the
  # gate read visibility from the DEFAULT project — a DIFFERENT tenant than the
  # (correctly-scoped) row read.
  #
  # The split-brain, made deterministic: the SAME schema name "shared" exists in
  # workspace A (`private`) and in the seeded DEFAULT project (`public`), sharing
  # the dataset STRING. A read SCOPED to A must see A's `private` → gate CLOSED.
  # The pre-fix no-opts read resolves the dataset_id via the Default project and
  # surfaces Default's `public` row → gate OPEN against A's data: a latent
  # cross-tenant auth bypass.
  defp a_private_default_public do
    {_def_ws, def_proj} = ensure_default_scope!()

    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_default = [workspace_id: def_proj.workspace_id, project_id: def_proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "shared", "title" => "Shared", "visibility" => "private", "fields" => []},
        @ds,
        scope_a
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "shared", "title" => "Shared", "visibility" => "public", "fields" => []},
        @ds,
        scope_default
      )

    {scope_a, scope_default}
  end

  test "schema_public? scoped to A reflects A's visibility (private → false), not Default's public" do
    {scope_a, scope_default} = a_private_default_public()

    # The fix: the gate resolves "shared" in the SAME tenant as the row read.
    # A owns the PRIVATE "shared" → gate CLOSED for an A-scoped public read.
    refute Content.schema_public?("shared", @ds, scope_a),
           "split-brain: A's gate read PUBLIC visibility — it must read A's own " <>
             "PRIVATE \"shared\", not the Default project's row"

    # Mirror (never-worse): Default owns the PUBLIC "shared" → gate OPEN there.
    assert Content.schema_public?("shared", @ds, scope_default),
           "Default's own public schema must still open the gate under its scope"
  end

  test "schema_public? WITHOUT scope reads the DEFAULT tenant's visibility (proves split-brain)" do
    {scope_a, _scope_default} = a_private_default_public()

    # A's own scoped gate is correctly CLOSED (A's "shared" is private).
    refute Content.schema_public?("shared", @ds, scope_a)

    # The pre-fix call shape — no opts. `resolve_read_dataset_id` falls back to
    # the Default project, so the gate surfaces Default's PUBLIC "shared" and
    # returns TRUE. That is the split-brain: this gate (Default) DISAGREES with
    # the A-scoped row read (private) — a public-read would be admitted against
    # A's tenant. Post-fix, every gate call site threads scope, so the gate
    # resolves in the caller's workspace and this disagreement is unreachable.
    assert Content.schema_public?("shared", @ds),
           "expected the no-opts gate to read the DEFAULT project's PUBLIC \"shared\""

    refute Content.schema_public?("shared", @ds, scope_a),
           "the A-scoped gate must DISAGREE with the no-opts/Default gate — that " <>
             "disagreement is the latent cross-tenant auth bypass su54 closes"
  end
end
