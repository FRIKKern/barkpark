defmodule BarkparkWeb.WorkspaceImportOrgConfinementTest do
  @moduledoc """
  A workspace bundle import by a caller the operator allowlist does not name
  stays inside the bundle's own workspace (task-1a6cde75b0adae76,
  `WorkspaceBundle.ImportConfinement`).

  In every mode: a new workspace lands in no organization, an existing one keeps
  its own, every row stays in the workspace, and rows that name a user are not
  written. Observe first (`BARKPARK_IMPORT_CONFINEMENT`, default observe): the
  target-admin rule and the withholding of seats, tokens and secrets. A listed
  operator's import is unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.Archive
  alias Barkpark.AccountsFixtures

  import Ecto.Query

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp verified(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token
  end

  defp operator_token(label) do
    n = System.unique_integer([:positive])
    raw = "#{label}-#{n}"

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "#{label}-home-#{n}", name: "#{label} home #{n}"})

    {:ok, token} = Auth.create_token(raw, label, "test", ["read", "write", "admin"], ws.id)
    {raw, token, ws}
  end

  # Export a workspace (optionally placed in `org_id` first), then delete it so
  # the import lands in a clean target — the bundle still CARRIES the org id.
  # `seated_user`, when given, holds a member seat in the source workspace.
  defp source_bundle!(org_id, seated_user \\ nil) do
    n = System.unique_integer([:positive])
    raw_src = "org-conf-source-#{n}"
    {:ok, src} = Auth.create_token(raw_src, "source owner", "test", ["read", "write", "admin"])

    {:ok, target} =
      Tenancy.create_workspace_with_owner(%{name: "Imported WS #{n}"}, verified(raw_src))

    if org_id, do: {:ok, _} = Tenancy.assign_workspace_to_organization(target, org_id)

    if seated_user,
      do: {:ok, _} = TenancyAuth.create_membership(target.id, seated_user.id, "member", "user")

    project = Tenancy.get_project(target.slug, "default")
    {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

    {:ok, bundle} = WorkspaceBundle.export(target.id)

    ws_id = target.id
    ws_slug = target.slug
    {:ok, ws_bin} = Ecto.UUID.dump(ws_id)

    {:ok, _} = Tenancy.delete_workspace(target)
    purge_fkless_audit!(ws_bin)
    refute Tenancy.get_workspace_by_slug(ws_slug)

    %{bundle: bundle, ws_id: ws_id, ws_slug: ws_slug, src_principal: src.id}
  end

  defp purge_fkless_audit!(ws_bin) do
    Repo.query!("SET session_replication_role = replica", [])

    try do
      Repo.query!("DELETE FROM audit_events WHERE workspace_id = $1", [ws_bin])
      Repo.query!("DELETE FROM audit_export_sinks WHERE workspace_id = $1", [ws_bin])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end
  end

  defp import_bundle(conn, raw, slug, bundle) do
    conn
    |> authed(raw)
    |> put_req_header("content-type", "application/x-tar")
    |> post("/api/workspaces/#{slug}/import", bundle)
  end

  # Set `column` to `value` on every row of the bundle's `table` member.
  defp rewrite_column(bundle, table, column, value) do
    {manifest, dumps} = Archive.unpack(bundle)
    entry = Enum.find(manifest["tables"], &(&1["name"] == table))
    i = Enum.find_index(entry["columns"], &(&1 == column))

    body =
      dumps[table]
      |> String.split("\n", trim: true)
      |> Enum.map_join(
        "",
        &((&1 |> String.split("\t") |> List.replace_at(i, value) |> Enum.join("\t")) <> "\n")
      )

    repack(manifest, Map.put(dumps, table, body))
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

  defp victim_workspace! do
    n = System.unique_integer([:positive])
    raw = "victim-rows-#{n}"
    {:ok, _} = Auth.create_token(raw, "victim owner", "test", ["read", "write", "admin"])
    {:ok, ws} = Tenancy.create_workspace_with_owner(%{name: "Victim rows #{n}"}, verified(raw))
    project = Tenancy.get_project(ws.slug, "default")
    assert project
    {:ok, _doc} = TenancyFixtures.create_document_in!(ws, project, "post", %{}, "test")
    {ws, project}
  end

  defp doc_count(ws_id) do
    Repo.query!("SELECT count(*) FROM documents WHERE workspace_id = $1::uuid", [
      Ecto.UUID.dump!(ws_id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp enforce! do
    Application.put_env(:barkpark, :import_confinement, :enforce)
    on_exit(fn -> Application.delete_env(:barkpark, :import_confinement) end)
  end

  defp observed_rows(ws_id) do
    Repo.query!(
      "SELECT metadata FROM audit_events WHERE action = $1 AND workspace_id = $2::uuid",
      ["workspace_import.confinement_observed", Ecto.UUID.dump!(ws_id)]
    ).rows
    |> List.flatten()
  end

  defp org!(label) do
    n = System.unique_integer([:positive])
    {:ok, org} = Tenancy.create_organization(%{name: "#{label} #{n}", slug: "#{label}-#{n}"})
    org
  end

  # An org route the caller may use only as an admin of EVERY workspace in it.
  defp set_auth_methods(raw, org) do
    scoped_conn()
    |> authed(raw)
    |> put_req_header("content-type", "application/json")
    |> put("/v1/admin/orgs/#{org.slug}/auth-methods", Jason.encode!(%{methods: ["sso"]}))
  end

  defp org_of(ws_id) do
    Repo.query!("SELECT organization_id::text FROM workspaces WHERE id = $1::uuid", [
      Ecto.UUID.dump!(ws_id)
    ]).rows
    |> hd()
    |> hd()
  end

  describe "a non-operator import cannot carry organization_id" do
    test "a bundle naming the importer's OWN new org lands in NO org", %{conn: conn} do
      org = org!("attacker-org")
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!(org.id)
      {raw_op, _op, _} = operator_token("own-org")

      assert import_bundle(conn, raw_op, slug, bundle).status == 200
      assert org_of(ws_id) == nil

      # The org stays empty, so the importer gains no org route.
      assert set_auth_methods(raw_op, org).status == 403
    end

    test "a bundle naming a FOREIGN org does not attach to it and leaves it untouched",
         %{conn: conn} do
      # A real org with a real workspace and its admin.
      {raw_victim, victim_tok, _} = operator_token("org-admin")

      org = org!("victim-org")

      {:ok, real_ws} =
        Tenancy.create_workspace(%{
          slug: "victim-ws-#{System.unique_integer([:positive])}",
          name: "Victim WS"
        })

      {:ok, _} = Tenancy.assign_workspace_to_organization(real_ws, org.id)
      {:ok, _} = TenancyAuth.create_membership(real_ws.id, victim_tok.id, "admin", "api_token")

      # The attacker's bundle names the victim org.
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!(org.id)
      {raw_op, _op, _} = operator_token("foreign-org")

      assert import_bundle(conn, raw_op, slug, bundle).status == 200

      # The imported workspace is in no org; the victim org still holds only its
      # real workspace, so its admin still administers every workspace in it.
      assert org_of(ws_id) == nil
      assert Tenancy.workspaces_for_organization(org.id) |> Enum.map(& &1.id) == [real_ws.id]
      assert set_auth_methods(raw_victim, org).status == 200
    end
  end

  describe "an existing workspace keeps its own org" do
    setup do
      Application.put_env(:barkpark, :allow_bundle_import, true)
      on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)
    end

    defp merge_import(raw, slug, bundle) do
      scoped_conn()
      |> authed(raw)
      |> put_req_header("content-type", "application/x-tar")
      |> post("/api/workspaces/#{slug}/import?mode=merge", bundle)
    end

    # A live workspace, exported while in `bundle_org`, then moved to
    # `resident_org`: the bundle names one org, the row holds another.
    defp resident!(admin_token, bundle_org, resident_org) do
      n = System.unique_integer([:positive])
      {:ok, ws} = Tenancy.create_workspace(%{slug: "resident-#{n}", name: "Resident #{n}"})

      if admin_token,
        do: {:ok, _} = TenancyAuth.create_membership(ws.id, admin_token.id, "admin", "api_token")

      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, bundle_org.id)
      {:ok, bundle} = WorkspaceBundle.export(ws.id)
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, resident_org && resident_org.id)
      {ws, bundle}
    end

    test "a merge into an existing workspace keeps its CURRENT org, not the bundle's" do
      {raw_op, op, _} = operator_token("resident")
      {ws, bundle} = resident!(op, org!("bundle-org"), resident = org!("resident-org"))

      assert merge_import(raw_op, ws.slug, bundle).status == 200
      assert org_of(ws.id) == resident.id
    end

    test "an existing workspace in NO org stays in no org" do
      {raw_op, op, _} = operator_token("resident-none")
      {ws, bundle} = resident!(op, org!("bundle-org"), nil)

      assert merge_import(raw_op, ws.slug, bundle).status == 200
      assert org_of(ws.id) == nil
    end

    test "observe: a non-admin's merge into an existing workspace goes through, keeps its org, and is recorded" do
      {raw_op, _op, _} = operator_token("non-admin-observe")
      {ws, bundle} = resident!(nil, org!("bundle-org"), resident = org!("resident-org"))

      assert merge_import(raw_op, ws.slug, bundle).status == 200
      assert org_of(ws.id) == resident.id
      assert [%{"would_refuse" => [%{"verb" => "import into"}]}] = observed_rows(ws.id)
    end

    test "enforce: a merge into an existing workspace the importer does not administer is refused 422" do
      enforce!()
      {raw_op, _op, _} = operator_token("non-admin")
      {ws, bundle} = resident!(nil, org!("bundle-org"), resident = org!("resident-org"))

      assert merge_import(raw_op, ws.slug, bundle).status == 422
      assert org_of(ws.id) == resident.id
    end

    test "enforce: replacing an empty same-slug shell needs the shell's admin" do
      enforce!()
      %{bundle: bundle, ws_slug: slug} = source_bundle!(nil)
      {raw_op, _op, _} = operator_token("shell")
      {:ok, shell} = Tenancy.create_workspace(%{slug: slug, name: "Shell #{slug}"})

      assert merge_import(raw_op, slug, bundle).status == 422
      assert Tenancy.get_workspace_by_slug(slug).id == shell.id
    end

    test "observe: replacing an empty same-slug shell goes through and is recorded" do
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!(nil)
      {raw_op, _op, _} = operator_token("shell-observe")
      {:ok, _shell} = Tenancy.create_workspace(%{slug: slug, name: "Shell #{slug}"})

      assert merge_import(raw_op, slug, bundle).status == 200
      assert Tenancy.get_workspace_by_slug(slug).id == ws_id
      assert [%{"would_refuse" => [%{"verb" => "replace"}]}] = observed_rows(ws_id)
    end
  end

  describe "a listed operator's import is unchanged" do
    test "the operator's import carries organization_id from the bundle", %{conn: conn} do
      org = org!("op-org")
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!(org.id)
      {raw_op, op, _} = operator_token("listed-op")

      Application.put_env(:barkpark, :operator_token_ids, [op.id])
      on_exit(fn -> Application.delete_env(:barkpark, :operator_token_ids) end)

      assert import_bundle(conn, raw_op, slug, bundle).status == 200
      assert org_of(ws_id) == org.id
    end
  end

  describe "every row stays in the bundle's workspace" do
    test "a row naming another workspace's workspace_id refuses the whole import 422",
         %{conn: conn} do
      {victim, _project} = victim_workspace!()
      %{bundle: bundle, ws_slug: slug} = source_bundle!(nil)
      {raw_op, _op, _} = operator_token("rows-e1")

      crafted = rewrite_column(bundle, "documents", "workspace_id", victim.id)

      assert import_bundle(conn, raw_op, slug, crafted).status == 422
      assert doc_count(victim.id) == 1
      refute Tenancy.get_workspace_by_slug(slug)
    end

    test "a row whose foreign key names another workspace's row refuses 422", %{conn: conn} do
      {_victim, project} = victim_workspace!()
      %{bundle: bundle, ws_slug: slug} = source_bundle!(nil)
      {raw_op, _op, _} = operator_token("rows-fk")

      crafted = rewrite_column(bundle, "documents", "project_id", project.id)

      assert import_bundle(conn, raw_op, slug, crafted).status == 422
      refute Tenancy.get_workspace_by_slug(slug)
    end
  end

  describe "seats, tokens and secrets" do
    test "observe: token seats travel as today; what enforce would withhold is recorded",
         %{conn: conn} do
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id, src_principal: src} = source_bundle!(nil)
      {raw_op, op, _} = operator_token("seats-observe")

      resp = import_bundle(conn, raw_op, slug, bundle)
      assert resp.status == 200
      refute Map.has_key?(Jason.decode!(resp.resp_body), "withheld")

      ids =
        Repo.all(from m in Membership, where: m.workspace_id == ^ws_id, select: m.principal_id)

      assert Enum.sort(ids) == Enum.sort([src, op.id])

      assert [%{"would_withhold" => %{"workspace_memberships" => 1}}] = observed_rows(ws_id)
    end

    test "enforce: only the importer's seat is written, and the receipt names what was withheld",
         %{conn: conn} do
      enforce!()
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!(nil)
      {raw_op, op, _} = operator_token("seats-enforce")

      resp = import_bundle(conn, raw_op, slug, bundle)
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["withheld"]["workspace_memberships"] == 1

      rows = Repo.all(from m in Membership, where: m.workspace_id == ^ws_id)
      assert Enum.map(rows, &{&1.principal_id, &1.role}) == [{op.id, "admin"}]
      assert observed_rows(ws_id) == []
    end

    test "every mode: a seat naming a USER is not written", %{conn: conn} do
      user =
        AccountsFixtures.register_user("seated-#{System.unique_integer([:positive])}@example.com")

      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!(nil, user)
      {raw_op, _op, _} = operator_token("user-seat")

      resp = import_bundle(conn, raw_op, slug, bundle)
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["withheld"]["workspace_memberships"] == 1

      refute Repo.exists?(
               from m in Membership,
                 where: m.workspace_id == ^ws_id and m.principal_id == ^user.id
             )
    end
  end
end
