defmodule Barkpark.Tenancy.WorkspaceBundleReservedSlugTest do
  @moduledoc """
  The workspace-bundle import restores the root `workspaces` row by a raw
  `COPY` (`copy_where("workspaces", :root, ctx)`), so it reaches the table
  through NEITHER guard that polices every other way a workspace is born:
  `Tenancy.singleton_slug_error/1` (the instance-default singleton) and
  `Workspace.changeset/2`'s `validate_exclusion(:slug, @reserved_slugs)` (the
  routing prefixes). task-545166efceb1bc91.

  WHY THE SEAT IS WORTH TAKING. `Tenancy.get_default_workspace/0` is
  `Repo.get_by(Workspace, slug: "default")`. Whoever holds that slug IS the
  instance default — `AssignDefaultScope` binds every flat route to it and
  `Content.WriteScope.resolve_write_scope/1` stamps an UNSCOPED WRITE with it.
  The `unique_index(:workspaces, [:slug])` the import route leans on refuses a
  squat only while the seat is OCCUPIED; with the seat VACANT there is nothing
  to collide with and the COPY lands.

  THE EDGE THIS FILE PINS, in both directions:

    * REFUSED — a bundle whose root slug is reserved arriving while that seat
      is VACANT. Nothing on this instance holds the name, so the import would
      simply become the holder.

    * ALLOWED, and deliberately so — the same bundle arriving while the seat is
      held by an EMPTY shell **and the caller named that seat**. That is
      `bp cloud support add --ws default` (internal/cli/cloud_support_cmd.go):
      SupportResetDefaultWorkspaceStep → SupportAdminTokenStep (whose
      `Seeds.Shared.ensure_default_scope/0` re-mints an empty default) →
      merge-import, where the PDS-D9 adopt branch replaces the shell with the
      imported workspace ON PURPOSE.

  The engine still cannot tell that flow from an eviction by database state
  alone — but it no longer has to. `WorkspaceController.import/2` now threads
  the `:workspace_slug` the operator named in the path down as
  `:expected_root_slug`, and a bundle that disagrees with it is refused before
  the empty-shell DELETE (task-b8218812cee2e4cc). The adopt arm below is
  therefore driven with the expectation the support chain actually sends —
  `"default"` — and is a CONTROL for the supported flow, not a pinned residue.
  The refused arm lives at the HTTP edge, in
  `test/barkpark_web/controllers/workspace_import_expected_root_slug_test.exs`.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Repo, Tenancy}
  alias Barkpark.Seeds
  alias Barkpark.Tenancy.Workspace
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, InvalidBundleError}

  @singleton_slug "default"

  setup do
    # Vacate the seat by RENAME, not by the real teardown: the multi-table
    # cascade deadlocked against the test's own transaction under the shared
    # sandbox (Postgrex 40P01, documented in tenancy_singleton_slug_test.exs).
    # Every arm here needs only that `get_default_workspace/0` resolves to
    # nothing before the fixture builds its own "default"-slugged source.
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^@singleton_slug),
        set: [slug: "parked-for-reserved-slug-test"]
      )

    refute Tenancy.get_default_workspace()
    :ok
  end

  describe "a bundle cannot COPY its way into a VACANT reserved seat" do
    test "root slug \"default\" + VACANT seat → refused, and get_default_workspace/0 stays nil" do
      {src, bundle, src_manifest} = exported_source_with_slug!(@singleton_slug)

      # THE VACANCY WINDOW. The source is gone from this instance, so there is
      # no row for the unique index to refuse — the state the import route's
      # own comment ("unique_index refuses a slug squat") does not cover.
      purge!(src, src_manifest)
      refute Tenancy.get_default_workspace()

      outcome = import_outcome(bundle)

      captured = Tenancy.get_default_workspace()

      refute captured && captured.id == src.id,
             "CAPTURE: the bundle took the instance-default seat through the raw COPY path — " <>
               "Tenancy.get_default_workspace/0 now returns #{inspect(captured && captured.id)}, " <>
               "the IMPORTED workspace (src.id=#{src.id}). Import outcome: #{inspect(outcome)}"

      # …and the refusal is the caller-fixable 422 oracle, not an opaque 500.
      assert {:refused, %InvalidBundleError{code: "invalid_bundle"} = err} = outcome
      assert err.message =~ @singleton_slug
      assert err.message =~ "VACANT"

      # Fail-closed: the whole transaction rolled back, so not one row landed.
      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [src.id]) == 0
      refute Tenancy.get_default_workspace()
    end

    test "the SAME refusal covers Workspace.@reserved_slugs, not only the singleton" do
      # "media" can never be created through `Workspace.changeset/2`
      # (validate_exclusion), which is exactly why a raw COPY carrying it is a
      # crafted bundle. Renaming past the changeset is how the fixture builds
      # one at all.
      {src, bundle, src_manifest} = exported_source_with_slug!("media")

      purge!(src, src_manifest)

      assert {:refused, %InvalidBundleError{code: "invalid_bundle"} = err} =
               import_outcome(bundle)

      assert err.message =~ "media"

      assert scalar("SELECT count(*) FROM workspaces WHERE slug = $1", ["media"]) == 0
    end

    test "a manifest that UNDER-DECLARES its root slug is caught by the rows it landed" do
      # The pre-flight reads `manifest["workspace_slug"]` — a CLAIM. The
      # workspaces COPY member carries the truth. A bundle that declares an
      # innocuous slug while shipping a "default" row walks past the pre-flight
      # and is caught by the post-COPY re-read.
      {src, bundle, src_manifest} = exported_source_with_slug!(@singleton_slug)
      purge!(src, src_manifest)

      {manifest, dumps} = Archive.unpack(bundle)
      assert manifest["workspace_slug"] == @singleton_slug

      lying = repack(Map.put(manifest, "workspace_slug", "totally-innocuous"), dumps)

      outcome = import_outcome(lying)

      captured = Tenancy.get_default_workspace()

      refute captured && captured.id == src.id,
             "CAPTURE via a lying manifest: get_default_workspace/0 returns " <>
               "#{inspect(captured && captured.id)} (the imported workspace). " <>
               "Outcome: #{inspect(outcome)}"

      assert {:refused, %InvalidBundleError{code: "invalid_bundle"} = err} = outcome
      assert err.message =~ "CLAIMED reserved workspace slug"
    end
  end

  describe "the legitimate flows the guard must NOT break" do
    test "CONTROL — the support vacancy window still re-mints the Default seat " <>
           "(SupportResetDefaultWorkspaceStep → SupportAdminTokenStep)" do
      # SupportResetDefaultWorkspaceStep: `Tenancy.delete_workspace/1` on the
      # slug-resolved default workspace (internal/cli/cloud/support.go).
      seeded = create_workspace!(@singleton_slug)
      seeded_proj = create_project!(seeded, unique("seededproj"))

      {:ok, _doc} =
        create_document_in!(seeded, seeded_proj, "post", %{"doc_id" => "seed"}, "test")

      {:ok, _} = Tenancy.delete_workspace(seeded)

      # THE VACANCY WINDOW — the bracket tolerates exactly this state.
      refute Tenancy.get_default_workspace()

      # SupportAdminTokenStep re-runs adminTokenStep, whose
      # `Seeds.Shared.ensure_default_scope/0` re-mints the seat through
      # `Tenancy.create_workspace/1` — the INTERNAL creator, deliberately
      # unguarded.
      _ = Seeds.Shared.ensure_default_scope()

      reminted = Tenancy.get_default_workspace()

      assert match?(%Workspace{slug: @singleton_slug}, reminted),
             "the vacancy window no longer closes: ensure_default_scope/0 could not re-mint " <>
               "the Default seat; got #{inspect(reminted)}"

      refute reminted.id == seeded.id, "fixture assumption: the re-mint is a NEW workspace"
    end

    test "CONTROL — an empty-shell seat is still adopted when the CALLER NAMED \"default\" " <>
           "(the `bp cloud support add --ws default` flow), so this guard does not break " <>
           "provisioning" do
      {src, bundle, src_manifest} = exported_source_with_slug!(@singleton_slug)
      purge!(src, src_manifest)

      # SupportAdminTokenStep's ensure_default_scope: a PROVABLY empty default
      # (0 documents, 0 media_files) now holds the seat. The seat is OCCUPIED,
      # so the vacant-seat guard is silent and PDS-D9's adopt branch runs.
      _ = Seeds.Shared.ensure_default_scope()
      shell = Tenancy.get_default_workspace()
      assert shell
      refute shell.id == src.id

      # THE EXPECTATION IS THE WHOLE POINT (task-b8218812cee2e4cc). The support
      # chain POSTs to /api/workspaces/default/import, so the engine is driven
      # with expected_root_slug: "default" — the manifest agrees, and the
      # PDS-D9 adopt branch runs exactly as it always did. The eviction arm this
      # test used to pin as RESIDUE is now closed at the door: a caller who
      # names ANY other workspace is refused before the delete (proven over HTTP
      # in workspace_import_expected_root_slug_test.exs).
      assert {:imported, {:ok, stats}} =
               import_outcome(bundle, mode: :merge, expected_root_slug: @singleton_slug)

      assert stats.total_rows > 0

      landed = Tenancy.get_default_workspace()

      assert landed.id == src.id,
             "the supported support-chain flow regressed: the merge-import no longer adopts " <>
               "the empty default shell when the caller NAMED it; get_default_workspace/0 = " <>
               "#{inspect(landed.id)}"

      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [shell.id]) == 0
    end

    test "an ORDINARY (non-reserved) root slug is untouched on a vacant target" do
      {src, bundle, src_manifest} = exported_source_with_slug!(unique("ordinary"))
      purge!(src, src_manifest)

      assert {:imported, {:ok, stats}} = import_outcome(bundle)
      assert stats.total_rows > 0
      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [src.id]) == 1
    end
  end

  describe "the rule is CONSULTED, not restated" do
    test "Tenancy.reserved_workspace_slugs/0 composes the singleton with Workspace.reserved_slugs/0" do
      reserved = Tenancy.reserved_workspace_slugs()

      assert @singleton_slug in reserved
      assert Tenancy.default_singleton_slug?(@singleton_slug)

      for slug <- Workspace.reserved_slugs() do
        assert slug in reserved, "#{slug} dropped out of the shared reserved list"
        assert Tenancy.reserved_workspace_slug?(slug)
      end

      refute Tenancy.reserved_workspace_slug?("my-team")
      refute Tenancy.reserved_workspace_slug?(nil)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # A workspace carrying `slug`, with one document so the bundle has real rows,
  # exported. `Tenancy.create_workspace/1` runs `Workspace.changeset/2`, which
  # refuses @reserved_slugs outright — so the slug is stamped by `update_all`
  # AFTER creation, which is precisely the shape a crafted bundle has and the
  # shape the raw COPY path would otherwise wave through.
  defp exported_source_with_slug!(slug) do
    src = create_workspace!(unique("src"))
    proj = create_project!(src, unique("srcproj"))

    {:ok, _doc} =
      create_document_in!(src, proj, "post", %{"doc_id" => unique("d")}, "test")

    {1, _} = Repo.update_all(from(w in Workspace, where: w.id == ^src.id), set: [slug: slug])
    src = Repo.get!(Workspace, src.id)
    assert src.slug == slug

    {:ok, bundle} = WorkspaceBundle.export(src.id)
    {manifest, _} = Archive.unpack(bundle)
    assert manifest["workspace_slug"] == slug

    {src, bundle, manifest}
  end

  # `Tenancy.delete_workspace/1` runs the ordered product cascade, then the
  # manifest's own E1 members are swept by `workspace_id`. That second pass is
  # not belt-and-braces: `audit_events` carries `workspace_id` with NO FK to
  # `workspaces`, so the product delete leaves it behind and the re-import's
  # COPY of the same bigserial ids collides on `audit_events_pkey` — a fixture
  # artefact of exporting and re-importing inside ONE database, never a finding.
  defp purge!(%Workspace{} = ws, manifest) do
    {:ok, _} = Tenancy.delete_workspace(ws)

    # `session_replication_role = replica` for the sweep, exactly as
    # `purge_workspace!/2` in workspace_bundle_test.exs does: `audit_events` is
    # append-only (a trigger raises P0001 on DELETE), and the sweep is fixture
    # teardown, not product behaviour.
    Repo.query!("SET session_replication_role = replica", [])

    try do
      for %{"partition" => "E1", "name" => table} <- manifest["tables"] do
        Repo.query!(
          "DELETE FROM #{quote_ident(table)} WHERE workspace_id = $1::text::uuid",
          [ws.id]
        )
      end
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end

    refute Repo.get(Workspace, ws.id)
    :ok
  end

  defp quote_ident(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")

  # The engine refuses a crafted bundle by RAISING (the 422 invalid_bundle
  # oracle at the HTTP edge), so every arm has to name both outcomes to be able
  # to assert on the CAPTURE independently of the refusal shape — a test that
  # only `assert_raise`d would go red on today's code with a message about a
  # missing exception rather than about the seat that changed hands.
  defp import_outcome(bundle, opts \\ []) do
    {:imported, WorkspaceBundle.import_bundle(bundle, opts)}
  rescue
    e in InvalidBundleError -> {:refused, e}
  end

  defp repack(manifest, dumps) do
    dir = Archive.spill_dir()

    files =
      Map.new(dumps, fn {table, body} ->
        spill = Archive.spill_path(dir, table)
        File.write!(spill, body)
        {table, spill}
      end)

    path = Archive.pack(manifest, files, dir: dir)

    try do
      File.read!(path)
    after
      File.rm(path)
    end
  end

  defp scalar(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
