defmodule BarkparkWeb.WorkspaceImportExpectedRootSlugTest do
  @moduledoc """
  The HTTP edge of the root-slug EXPECTATION (task-b8218812cee2e4cc), the
  residue `workspace_bundle_reserved_slug_test.exs` used to pin as a live fact.

  THE CAPTURE, as it was. `POST /api/workspaces/:workspace_slug/import` carries
  the operator's named target in its path, and `WorkspaceController.import/2`
  bound it as `_slug` and threw it away. So a merge-import of a bundle whose
  ROOT slug is `"default"`, POSTed at ANY other workspace's path, reached
  `WorkspaceBundle.adopt_or_refuse_root_slug!/1` with the migrate-seeded Default
  holding the seat — provably empty (0 documents, 0 media_files), therefore a
  legitimate PDS-D9 adopt target BY STATE ALONE. The seed was DELETED and the
  imported workspace became `Tenancy.get_default_workspace/0`: the scope every
  unscoped flat read and write lands in (`AssignDefaultScope`,
  `Content.WriteScope.resolve_write_scope/1`).

  The engine could never close this alone — `bp cloud support add --ws default`
  drives the state-identical sequence on purpose. The path segment is where the
  two differ, so the controller now threads it down as `:expected_root_slug`
  and the engine refuses a disagreeing bundle BEFORE the delete.

  This file drives the REAL route with the REAL engine (no `:import_fault`
  seam): the refusal has to be provable end to end, because a seam-driven test
  could not have distinguished "refused" from "the engine was never reached".
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Repo, Seeds, Tenancy}
  alias Barkpark.Tenancy.Workspace
  alias Barkpark.Tenancy.WorkspaceBundle

  @singleton_slug "default"

  setup do
    Application.put_env(:barkpark, :allow_bundle_import, true)
    on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

    # Vacate the seat by RENAME, not the real teardown: the multi-table cascade
    # deadlocks against the test's own transaction under the shared sandbox
    # (Postgrex 40P01) — the same reason workspace_bundle_reserved_slug_test.exs
    # parks it. All this arm needs is a seat the fixture can build its own
    # "default"-slugged source under.
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^@singleton_slug),
        set: [slug: "parked-for-expected-root-slug-test"]
      )

    refute Tenancy.get_default_workspace()

    raw = "ws-expected-slug-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "ws admin", "test", ["read", "write", "admin"])

    {:ok, raw: raw}
  end

  test "a merge-import whose root slug is \"default\", POSTed at ANOTHER workspace's path, " <>
         "is REFUSED and the seeded Default keeps the seat",
       %{conn: conn, raw: raw} do
    {src, bundle} = exported_source_with_slug!(@singleton_slug)
    purge!(src)

    # SupportAdminTokenStep's `ensure_default_scope/0`: a PROVABLY empty Default
    # (0 documents, 0 media_files) holds the seat — the exact shape PDS-D9's
    # adopt branch treats as replaceable.
    _ = Seeds.Shared.ensure_default_scope()
    shell = Tenancy.get_default_workspace()
    assert shell
    refute shell.id == src.id

    # The operator names a DIFFERENT workspace in the path. That is the whole
    # signal: they did not ask to have the instance default replaced.
    other = create_workspace!(unique("other"))

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/x-tar")
      |> post("/api/workspaces/#{other.slug}/import?mode=merge", bundle)

    assert resp.status == 422,
           "the import was not refused (HTTP #{resp.status}) — a bundle whose root slug is " <>
             "#{inspect(@singleton_slug)} landed through a path naming #{inspect(other.slug)}"

    err = Jason.decode!(resp.resp_body)["error"]
    assert err["code"] == "invalid_bundle"
    assert err["message"] =~ other.slug
    assert err["message"] =~ @singleton_slug

    # THE CAPTURE ASSERTION, independent of the refusal shape: the seat.
    landed = Tenancy.get_default_workspace()

    assert landed && landed.id == shell.id,
           "CAPTURE: the instance-default seat changed hands — get_default_workspace/0 " <>
             "returns #{inspect(landed && landed.id)}, the seeded shell was #{shell.id} and " <>
             "the imported workspace is #{src.id}"

    # Fail-closed: nothing from the bundle landed at all.
    assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [src.id]) == 0
  end

  test "the SUPPORTED flow is untouched — the same bundle POSTed at /api/workspaces/default/" <>
         "import adopts the empty shell, exactly as `bp cloud support add --ws default` does",
       %{conn: conn, raw: raw} do
    {src, bundle} = exported_source_with_slug!(@singleton_slug)
    purge!(src)

    _ = Seeds.Shared.ensure_default_scope()
    shell = Tenancy.get_default_workspace()
    assert shell

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/x-tar")
      |> post("/api/workspaces/#{@singleton_slug}/import?mode=merge", bundle)

    assert resp.status == 200,
           "the guard over-reached: the support chain's own request answered " <>
             "HTTP #{resp.status} — #{resp.resp_body}"

    landed = Tenancy.get_default_workspace()

    assert landed && landed.id == src.id,
           "the supported flow regressed: the adopt branch no longer replaces the empty " <>
             "Default shell when the caller NAMED it"

    assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [shell.id]) == 0
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A workspace carrying `slug`, with one document so the bundle has real rows,
  # exported. `Tenancy.create_workspace/1` runs `Workspace.changeset/2`, which
  # refuses the reserved slugs outright — so the slug is stamped by `update_all`
  # AFTER creation, the same shape a crafted bundle has.
  defp exported_source_with_slug!(slug) do
    src = create_workspace!(unique("src"))
    proj = create_project!(src, unique("srcproj"))
    {:ok, _doc} = create_document_in!(src, proj, "post", %{"doc_id" => unique("d")}, "test")

    {1, _} = Repo.update_all(from(w in Workspace, where: w.id == ^src.id), set: [slug: slug])
    src = Repo.get!(Workspace, src.id)
    assert src.slug == slug

    {:ok, bundle} = WorkspaceBundle.export(src.id)
    {src, bundle}
  end

  # Remove the source from this instance so the re-import is a genuine restore
  # rather than a same-id no-op. `audit_events` carries `workspace_id` with NO
  # FK to `workspaces`, so the product cascade leaves it behind and the
  # re-import's COPY of the same bigserial ids would collide on
  # `audit_events_pkey` — a fixture artefact of exporting and re-importing
  # inside ONE database, never a finding.
  defp purge!(%Workspace{} = ws) do
    {:ok, _} = Tenancy.delete_workspace(ws)

    Repo.query!("SET session_replication_role = replica", [])

    try do
      Repo.query!("DELETE FROM audit_events WHERE workspace_id = $1::text::uuid", [ws.id])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end

    refute Repo.get(Workspace, ws.id)
    :ok
  end

  defp scalar(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()
end
