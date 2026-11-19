defmodule Barkpark.Tenancy.WorkspaceBundleSeatChangeTest do
  @moduledoc """
  The seat change stamp across a workspace bundle (task-018e79d8734a1b08).

  * The export leaves `seat_change` out, so seat rows keep the shape they had
    before the column.
  * Every seat row an import writes (merge, observed or operator; clean) gets
    a new stamp from this database, so a role request the target made before
    the import is stale after it: promoted, demoted or removed in the target,
    the import putting the old seat row back does not make it approvable.
  * A bundle that names `seat_change` is refused before anything commits.
  """
  use Barkpark.DataCase, async: false

  @moduletag :capture_log

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.Tenancy.{AccessRequests, Members, Membership, Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog, InvalidBundleError}

  setup do
    prev = System.get_env("BARKPARK_IMPORT_CONFINEMENT")

    on_exit(fn ->
      if prev,
        do: System.put_env("BARKPARK_IMPORT_CONFINEMENT", prev),
        else: System.delete_env("BARKPARK_IMPORT_CONFINEMENT")
    end)

    :ok
  end

  defp token!(ws, role) do
    raw = "bsc-#{role}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "bsc", "production", ~w(read write admin))
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")
    token
  end

  defp role!(ws, name, actions) do
    {:ok, r} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws.id}))

    for a <- actions,
        do:
          {:ok, _} =
            Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: r.id, action: a}))
  end

  # U is seated as `viewer`; the bundle is exported with U's seat in it.
  defp fixture do
    ws = create_workspace!("bsc-#{System.unique_integer([:positive])}")
    _ = create_project!(ws)
    role!(ws, "viewer", ~w(read))
    role!(ws, "bottom", [])

    {:ok, u} =
      Accounts.register_user(%{
        email: "bsc-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    u = Accounts.confirm_provisioned_user(u)
    {:ok, _} = TenancyAuth.create_membership(ws.id, u.id, "viewer", "user")
    f = %{ws: ws, u: u, importer: token!(ws, "admin"), approver: token!(ws, "admin")}
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    Map.put(f, :bundle, bundle)
  end

  defp opts(:operator, _f), do: [mode: :merge]

  defp opts(mode, f) do
    System.put_env("BARKPARK_IMPORT_CONFINEMENT", Atom.to_string(mode))
    [mode: :merge, confine: true, grant_admin_to: {f.importer.id, "api_token"}]
  end

  defp stamps(ws_id) do
    from(m in Membership, where: m.workspace_id == ^ws_id, select: {m.id, m.seat_change})
    |> Repo.all()
    |> Map.new()
  end

  defp seat_role(f) do
    case TenancyAuth.membership(f.u.id, f.ws.id, :user) do
      nil -> nil
      seat -> seat.role
    end
  end

  # `audit_events` has no FK, so its rows outlive the workspace; the bundle
  # carries them, and a clean import would collide with them.
  defp drop_audit_rows!(ws_id) do
    Repo.query!("SET session_replication_role = replica", [])

    try do
      Repo.query!("DELETE FROM audit_events WHERE workspace_id = $1::uuid", [
        Ecto.UUID.dump!(ws_id)
      ])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end
  end

  defp member(manifest, table), do: Enum.find(manifest["tables"], &(&1["name"] == table))

  # The reviewer's cases (review_import_seat_rewrite_test.exs): the target's
  # own role request, the seat changed in the target, then a merge import
  # puts the source's seat row back.
  for mode <- [:enforce, :observe, :operator], change <- [:promoted, :demoted, :removed] do
    @mode mode
    @change change

    test "#{mode}: a role request, seat #{change} after the ask, then a merge import: stale" do
      f = fixture()
      {:ok, %{id: rid}} = AccessRequests.request(f.u, f.ws.slug, nil, "admin")
      seat = %{type: :user, id: f.u.id}

      case @change do
        :promoted -> {:ok, _} = Members.update_role(f.ws.id, seat, "member")
        :demoted -> {:ok, _} = Members.update_role(f.ws.id, seat, "bottom")
        :removed -> {:ok, _} = Members.remove_member(f.ws.id, seat)
      end

      assert [%{stale: true}] = AccessRequests.list_pending(f.ws.id)
      assert {:ok, _} = WorkspaceBundle.import_bundle(f.bundle, opts(@mode, f))
      after_import = seat_role(f)

      assert [%{stale: true}] = AccessRequests.list_pending(f.ws.id)
      assert AccessRequests.approve(f.ws.id, rid, nil, f.approver) == {:error, :request_stale}
      assert seat_role(f) == after_import
    end
  end

  for mode <- [:observe, :operator] do
    @mode mode

    test "#{mode}: every seat a merge import writes gets a new stamp" do
      f = fixture()
      before = stamps(f.ws.id)
      {manifest, _} = Archive.unpack(f.bundle)
      assert member(manifest, "workspace_memberships")["row_count"] == map_size(before)

      assert {:ok, _} = WorkspaceBundle.import_bundle(f.bundle, opts(@mode, f))
      later = stamps(f.ws.id)

      for {id, stamp} <- before,
          do: assert(later[id] not in [nil, stamp], "seat #{id} kept its stamp")
    end
  end

  test "clean: every seat a restore writes gets a new stamp" do
    f = fixture()
    before = stamps(f.ws.id)
    assert {:ok, _} = Tenancy.delete_workspace(f.ws)
    drop_audit_rows!(f.ws.id)

    assert {:ok, _} = WorkspaceBundle.import_bundle(f.bundle)
    later = stamps(f.ws.id)
    assert Map.keys(later) == Map.keys(before)

    for {id, stamp} <- before,
        do: assert(later[id] != stamp, "seat #{id} kept its stamp")
  end

  test "the export leaves seat_change out; seat rows keep the shape they had before it" do
    f = fixture()
    {manifest, dumps} = Archive.unpack(f.bundle)

    for table <- ["workspace_memberships", "workspace_access_requests"] do
      cols = member(manifest, table)["columns"]
      refute "seat_change" in cols
      assert cols == Catalog.non_generated_columns(Repo, table) -- ["seat_change"]
    end

    cols = member(manifest, "workspace_memberships")["columns"]

    for row <- String.split(dumps["workspace_memberships"], "\n", trim: true),
        do: assert(length(String.split(row, "\t")) == length(cols))
  end

  for mode <- [:merge, :clean] do
    @mode mode

    test "#{mode}: a bundle that names seat_change is refused and writes nothing" do
      f = fixture()
      {manifest, dumps} = Archive.unpack(f.bundle)
      forged = "00000000-0000-0000-0000-0000000000aa"

      manifest =
        Map.update!(manifest, "tables", fn tables ->
          Enum.map(tables, fn
            %{"name" => "workspace_memberships"} = m ->
              Map.update!(m, "columns", &(&1 ++ ["seat_change"]))

            m ->
              m
          end)
        end)

      dumps =
        Map.update!(dumps, "workspace_memberships", fn body ->
          body
          |> String.split("\n", trim: true)
          |> Enum.map_join("", &(&1 <> "\t" <> forged <> "\n"))
        end)

      bundle = repack(manifest, dumps)

      if @mode == :clean do
        assert {:ok, _} = Tenancy.delete_workspace(f.ws)
        drop_audit_rows!(f.ws.id)
      end

      before = stamps(f.ws.id)

      assert_raise InvalidBundleError, ~r/seat_change/, fn ->
        WorkspaceBundle.import_bundle(bundle, mode: @mode)
      end

      assert stamps(f.ws.id) == before
      refute forged in Map.values(stamps(f.ws.id))
    end
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
end
