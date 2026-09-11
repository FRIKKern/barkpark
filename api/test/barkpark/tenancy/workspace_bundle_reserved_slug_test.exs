defmodule Barkpark.Tenancy.WorkspaceBundleReservedSlugTest do
  @moduledoc """
  The workspace-bundle import restores the root `workspaces` row by a raw
  `COPY` (`copy_where("workspaces", :root, ctx)`), so it reaches the table
  through NEITHER guard that polices every other way a workspace is born:
  `Tenancy.singleton_slug_error/1` (the instance-default singleton) and
  `Workspace.changeset/2`'s `validate_exclusion(:slug, @reserved_slugs)` (the
  routing prefixes). task-545166efceb1bc91.

  WHY THE SEAT IS WORTH TAKING. `Tenancy.get_default_workspace/0` reads the
  uncast `workspaces.is_default` column (task-566dc5be4871353b); it used to be
  `Repo.get_by(Workspace, slug: "default")`, and whoever held that slug WAS the
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
    # Vacate the seat WITHOUT the real teardown: the multi-table cascade
    # deadlocked against the test's own transaction under the shared sandbox
    # (Postgrex 40P01, documented in tenancy_singleton_slug_test.exs). Every arm
    # here needs only that `get_default_workspace/0` resolves to nothing before
    # the fixture builds its own "default"-slugged source.
    #
    # THIS SETUP USED TO BE A RENAME ALONE, and that it no longer suffices is
    # the whole of task-566dc5be4871353b in one statement. While the seat WAS
    # the `default` slug, moving the slug moved the seat — which is precisely
    # the residue PR #12879 could not close, because `Workspace.changeset/2`
    # casts `:slug` and any future `update_workspace/2` would have handed a
    # principal the instance default for free. The seat is now
    # `workspaces.is_default`, which no changeset casts, so the rename below is
    # inert and the flag has to be cleared explicitly.
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^@singleton_slug),
        set: [slug: "parked-for-reserved-slug-test"]
      )

    # THE RENAME PATH IS CLOSED — asserted here rather than in prose, and in the
    # one place a regression would silently make every arm below vacuous: if the
    # seat ever becomes slug-derived again, this refute reds and names why.
    parked = Tenancy.get_default_workspace()

    assert match?(%Workspace{slug: "parked-for-reserved-slug-test"}, parked),
           "RENAME MOVED THE SEAT: get_default_workspace/0 stopped resolving the renamed " <>
             "workspace, so the singleton is once again identified by a mutable, " <>
             "user-claimable string (task-566dc5be4871353b); got #{inspect(parked)}"

    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.is_default == true),
        set: [is_default: false]
      )

    Barkpark.Tenancy.DefaultScopeCache.invalidate()

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

  describe "the instance-default SEAT cannot travel in a bundle (task-566dc5be4871353b)" do
    test "a CRAFTED bundle shipping is_default = t cannot CAPTURE the vacant seat" do
      # The seat is no longer a string, so `assert_root_slug_not_vacant_reserved!/2`
      # — which polices reserved SLUGS — sees nothing wrong with this bundle: its
      # root slug is ordinary. The claim rides in the COLUMN instead, through the
      # raw COPY that reaches no changeset. If `settle_default_seat!/2` did not
      # clear it, moving the seat off the slug would have RELOCATED the capture
      # rather than closed it.
      {src, bundle, src_manifest} = exported_source_with_slug!(unique("ordinary"))
      purge!(src, src_manifest)
      refute Tenancy.get_default_workspace()

      {manifest, dumps} = Archive.unpack(bundle)
      crafted = repack(manifest, Map.put(dumps, "workspaces", claim_seat(manifest, dumps)))

      # Fixture assumption, asserted: the tampering actually landed a `t`.
      assert seat_byte(manifest, Map.put(dumps, "workspaces", claim_seat(manifest, dumps))) == "t"

      outcome = import_outcome(crafted)
      assert {:imported, {:ok, _stats}} = outcome

      captured = Tenancy.get_default_workspace()

      refute captured,
             "CAPTURE THROUGH THE COLUMN: a caller-supplied bundle claimed the " <>
               "instance-default seat by shipping is_default = t in the workspaces " <>
               "member — get_default_workspace/0 now returns #{inspect(captured && captured.id)} " <>
               "(imported workspace src.id=#{src.id}). Import outcome: #{inspect(outcome)}"

      # DEGRADED TO VACANCY, not to capture: the workspace itself landed fine.
      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [src.id]) == 1
    end

    test "a CRAFTED bundle cannot STEAL a seat another workspace already holds" do
      {src, bundle, src_manifest} = exported_source_with_slug!(unique("ordinary"))
      purge!(src, src_manifest)

      holder = Tenancy.establish_default_workspace!()

      {manifest, dumps} = Archive.unpack(bundle)
      crafted = repack(manifest, Map.put(dumps, "workspaces", claim_seat(manifest, dumps)))

      # WHICH WALL CATCHES IT, and why it is the coarser one. `settle_default_seat!/2`
      # runs after the members land, so with the seat OCCUPIED the partial unique
      # index gets there first and aborts the COPY — a Postgrex 23505, which the
      # HTTP edge renders as a logged 500 rather than the 422 invalid_bundle a
      # crafted bundle normally earns. That asymmetry is deliberate and stated
      # rather than papered over: the DANGEROUS arm is the vacant seat (the arm
      # above), and that one is closed cleanly by the clear. This arm cannot
      # capture anything — the seat is already held — so it is worth exactly one
      # fail-closed rollback and no extra pre-flight pass over the dump.
      err =
        assert_raise Postgrex.Error, fn ->
          WorkspaceBundle.import_bundle(crafted)
        end

      assert err.postgres.constraint == "workspaces_single_default_index"

      assert Tenancy.get_default_workspace().id == holder.id,
             "a crafted bundle took the seat away from the workspace holding it"

      # Fail-closed: the abort rolled the whole import back.
      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [src.id]) == 0
    end

    test "the EXPORT never carries a live seat out of the instance" do
      src = create_workspace!(unique("src"))
      proj = create_project!(src, unique("srcproj"))
      {:ok, _doc} = create_document_in!(src, proj, "post", %{"doc_id" => unique("d")}, "test")

      # Put THIS workspace in the seat, then export it.
      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^src.id), set: [is_default: true])

      Barkpark.Tenancy.DefaultScopeCache.invalidate()
      assert Tenancy.get_default_workspace().id == src.id

      {:ok, bundle} = WorkspaceBundle.export(src.id)
      {manifest, dumps} = Archive.unpack(bundle)

      assert seat_byte(manifest, dumps) == "f",
             "the exporter carried the instance-default seat into a bundle — landing that " <>
               "bundle anywhere else hands the seat to whoever runs the import"
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

  # The `is_default` field of the single root row in the `workspaces` member,
  # read out of the COPY text by the manifest's own column order (never by a
  # hard-coded index — the column list is the manifest's, and it moves).
  defp seat_index(manifest) do
    entry = Enum.find(manifest["tables"], &(&1["name"] == "workspaces"))
    idx = Enum.find_index(entry["columns"], &(&1 == "is_default"))

    assert idx,
           "the workspaces member no longer carries an is_default column — this whole " <>
             "describe block is measuring nothing"

    idx
  end

  defp seat_byte(manifest, dumps) do
    dumps
    |> Map.fetch!("workspaces")
    |> String.split("\n", trim: true)
    |> hd()
    |> String.split("\t")
    |> Enum.at(seat_index(manifest))
  end

  # The same dump with the root row's `is_default` flipped to `t` — a bundle no
  # honest exporter produces, which is exactly why the import may not trust one.
  defp claim_seat(manifest, dumps) do
    idx = seat_index(manifest)

    dumps
    |> Map.fetch!("workspaces")
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", fn line ->
      line |> String.split("\t") |> List.replace_at(idx, "t") |> Enum.join("\t")
    end)
    |> Kernel.<>("\n")
  end

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
