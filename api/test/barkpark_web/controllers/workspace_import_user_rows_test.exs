defmodule BarkparkWeb.WorkspaceImportUserRowsTest do
  @moduledoc """
  A workspace bundle import by a caller the operator allowlist does not name
  cannot carry user-bound credentials or seats for people outside the workspace
  (task-1a6cde75b0adae76, `WorkspaceBundle.ImportConfinement.Rows`). A
  user-owned token, its sessions and a user seat travel only for a user already
  seated in the existing target; the rest are withheld and listed. Default mode.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{AccountsFixtures, Auth, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.Archive

  import Ecto.Query

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp importer(label) do
    n = System.unique_integer([:positive])
    raw = "#{label}-#{n}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{label}-home-#{n}", name: "#{label} #{n}"})
    {:ok, token} = Auth.create_token(raw, label, "test", ["read", "write", "admin"], ws.id)
    {raw, token}
  end

  defp user!(label),
    do:
      AccountsFixtures.register_user("#{label}-#{System.unique_integer([:positive])}@example.com")

  defp workspace!(label) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{label}-#{n}", name: "#{label} #{n}"})
    project = Tenancy.get_project(ws.slug, "default")
    {:ok, _} = TenancyFixtures.create_document_in!(ws, project, "post", %{}, "test")
    ws
  end

  # A token minted in `ws` and owned by `user`: it acts as that user.
  defp user_token!(ws, user) do
    raw = "pat-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "pat", "test", ["read", "write", "admin"], ws.id)

    Repo.query!("UPDATE api_tokens SET owner_user_id = $1::uuid WHERE id = $2::uuid", [
      Ecto.UUID.dump!(user.id),
      Ecto.UUID.dump!(token.id)
    ])

    token
  end

  defp token_exists?(id),
    do: Repo.exists?(from t in "api_tokens", where: t.id == type(^id, :binary_id))

  defp user_seated?(ws_id, user_id) do
    Repo.exists?(
      from m in "workspace_memberships",
        where:
          m.workspace_id == type(^ws_id, :binary_id) and m.principal_type == "user" and
            m.principal_id == type(^user_id, :binary_id)
    )
  end

  defp import!(raw, slug, bundle, query \\ "") do
    resp =
      scoped_conn()
      |> authed(raw)
      |> put_req_header("content-type", "application/x-tar")
      |> post("/api/workspaces/#{slug}/import#{query}", bundle)

    assert resp.status == 200, resp.resp_body
    Jason.decode!(resp.resp_body)
  end

  # Export, then delete the workspace (and its FK-less audit rows, which the
  # bundle carries) so a clean import creates it anew.
  defp export_and_delete!(ws) do
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    {:ok, _} = Tenancy.delete_workspace(ws)
    Repo.query!("SET session_replication_role = replica", [])

    try do
      Repo.query!("DELETE FROM audit_events WHERE workspace_id = $1::uuid", [
        Ecto.UUID.dump!(ws.id)
      ])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end

    bundle
  end

  defp audit_rows(ws_id) do
    Repo.query!(
      "SELECT metadata FROM audit_events WHERE action = $1 AND workspace_id = $2::uuid",
      ["workspace_import.confinement", Ecto.UUID.dump!(ws_id)]
    ).rows
    |> List.flatten()
  end

  test "a token owned by a user outside the target is withheld and listed" do
    outsider = user!("outsider")
    ws = workspace!("impersonate")
    pat = user_token!(ws, outsider)
    bundle = export_and_delete!(ws)
    refute token_exists?(pat.id)
    {raw, _} = importer("impersonate")

    receipt = import!(raw, ws.slug, bundle)

    refute token_exists?(pat.id)
    expected = %{"rows" => 1, "user_ids" => [outsider.id]}
    assert receipt["withheld_user_rows"]["api_tokens"] == expected
    assert [%{"withheld_user_rows" => %{"api_tokens" => ^expected}}] = audit_rows(ws.id)
  end

  test "a seat for a user outside the target is withheld, so org SSO cannot adopt them" do
    outsider = user!("seat-outsider")
    ws = workspace!("outside-seat")
    {:ok, _} = TenancyAuth.create_membership(ws.id, outsider.id, "member", "user")
    bundle = export_and_delete!(ws)
    {raw, _} = importer("outside-seat")

    receipt = import!(raw, ws.slug, bundle)

    refute user_seated?(ws.id, outsider.id)

    assert receipt["withheld_user_rows"]["workspace_memberships"] ==
             %{"rows" => 1, "user_ids" => [outsider.id]}

    {:ok, org} = Tenancy.create_organization(%{name: "SSO org", slug: "sso-org-#{ws.slug}"})

    {:ok, _} =
      Tenancy.assign_workspace_to_organization(Tenancy.get_workspace_by_slug(ws.slug), org.id)

    assert Barkpark.Sso.org_login_user(org.id, outsider.email) ==
             {:error, :email_not_owned_by_org}
  end

  test "a restore over a live workspace keeps the tokens and seats of people already seated" do
    Application.put_env(:barkpark, :allow_bundle_import, true)
    on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

    member = user!("member")
    outsider = user!("restore-outsider")
    ws = workspace!("restore")
    {raw, op} = importer("restore")
    {:ok, _} = TenancyAuth.create_membership(ws.id, op.id, "admin", "api_token")
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "user")
    member_pat = user_token!(ws, member)
    outsider_pat = user_token!(ws, outsider)
    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    # The live workspace lost both tokens since the export.
    Repo.query!("DELETE FROM api_tokens WHERE id = ANY($1::uuid[])", [
      [Ecto.UUID.dump!(member_pat.id), Ecto.UUID.dump!(outsider_pat.id)]
    ])

    receipt = import!(raw, ws.slug, bundle, "?mode=merge")

    assert token_exists?(member_pat.id)
    assert user_seated?(ws.id, member.id)
    refute token_exists?(outsider_pat.id)

    assert receipt["withheld_user_rows"] == %{
             "api_tokens" => %{"rows" => 1, "user_ids" => [outsider.id]}
           }
  end

  # Aim a bundle at `target`: its root row dropped, only `keep` members kept,
  # every workspace_id rewritten to the target's.
  defp aim_at(bundle, target, keep) do
    {manifest, dumps} = Archive.unpack(bundle)

    {tables, dumps} =
      Enum.map_reduce(manifest["tables"], dumps, fn %{"name" => t} = e, acc ->
        if t in keep do
          {e, Map.put(acc, t, set_workspace_id(Map.get(acc, t, ""), e["columns"], target.id))}
        else
          {Map.put(e, "row_count", 0), Map.put(acc, t, "")}
        end
      end)

    manifest = %{manifest | "tables" => tables, "workspace_id" => target.id}
    repack(%{manifest | "workspace_slug" => target.slug}, dumps)
  end

  defp set_workspace_id(body, columns, ws_id) do
    i = Enum.find_index(columns, &(&1 == "workspace_id"))

    body
    |> String.split("\n", trim: true)
    |> Enum.map_join(
      &((&1 |> String.split("\t") |> List.replace_at(i, ws_id) |> Enum.join("\t")) <> "\n")
    )
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

  defp fingerprint(ws_id) do
    Repo.query!(
      """
      SELECT md5(concat_ws('|',
        (SELECT string_agg(t::text, ',' ORDER BY t::text) FROM api_tokens t WHERE workspace_id = $1),
        (SELECT string_agg(m::text, ',' ORDER BY m::text) FROM workspace_memberships m WHERE workspace_id = $1),
        (SELECT string_agg(d::text, ',' ORDER BY d::text) FROM documents d WHERE workspace_id = $1),
        (SELECT string_agg(w::text, ',' ORDER BY w::text) FROM workspaces w WHERE id = $1)))
      """,
      [Ecto.UUID.dump!(ws_id)]
    ).rows
    |> hd()
    |> hd()
  end

  test "a non-admin's import over a real workspace refuses 422 and changes nothing" do
    owner = user!("victim-owner")
    victim = workspace!("victim")
    {:ok, _} = TenancyAuth.create_membership(victim.id, owner.id, "owner", "user")

    src = workspace!("src")
    pat = user_token!(src, owner)
    bundle = export_and_delete!(src)
    Repo.query!("DELETE FROM api_tokens WHERE id = $1::uuid", [Ecto.UUID.dump!(pat.id)])
    crafted = aim_at(bundle, victim, ~w(api_tokens workspace_memberships))
    {raw, _} = importer("not-admin")
    before = fingerprint(victim.id)

    resp =
      scoped_conn()
      |> authed(raw)
      |> put_req_header("content-type", "application/x-tar")
      |> post("/api/workspaces/#{victim.slug}/import", crafted)

    assert resp.status == 422, resp.resp_body
    assert fingerprint(victim.id) == before
    refute token_exists?(pat.id)
  end
end
