defmodule Barkpark.Tenancy.WorkspaceBundleAccessRequestsTest do
  @moduledoc """
  task-7de56f0140625e56: a workspace import does not carry access requests;
  people ask again. In every mode (clean and merge; an operator's import, and a
  confined one observed or enforced) the target's own requests are exactly what
  they were before the import, and the result says how many the bundle carried
  (`access_requests_left_out`).

  Each case: U, with no seat, asks for one; the workspace is exported; the
  target then moves on (denies, approves, re-roles, removes, withdraws) and the
  bundle is imported over it.
  """
  use Barkpark.DataCase, async: false

  @moduletag :capture_log

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.Tenancy.{AccessRequest, AccessRequests, Members, Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.DatasetRemap

  @modes [:enforce, :observe, :operator]

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
    raw = "bar-#{role}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "bar", "production", ~w(read write admin))
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")
    token
  end

  defp user! do
    {:ok, user} =
      Accounts.register_user(%{
        email: "bar-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    Accounts.confirm_provisioned_user(user)
  end

  # U asks for a seat; `before_export` may reshape the source row first.
  defp fixture(before_export \\ fn _ -> :ok end) do
    ws = create_workspace!("bar-#{System.unique_integer([:positive])}")
    _ = create_project!(ws)
    {:ok, r} = Repo.insert(Role.changeset(%Role{}, %{name: "bottom", workspace_id: ws.id}))

    {:ok, _} =
      Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: r.id, action: "read"}))

    f = %{ws: ws, importer: token!(ws, "admin"), approver: token!(ws, "admin"), u: user!()}
    {:ok, %{id: rid}} = AccessRequests.request(f.u, ws.slug, "please")
    f = Map.put(f, :rid, rid)
    before_export.(f)
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    Map.put(f, :bundle, bundle)
  end

  # Every request row that names this workspace or this user, as plain maps.
  defp requests(f) do
    from(r in AccessRequest,
      where: r.workspace_id == ^f.ws.id or r.user_id == ^f.u.id,
      order_by: r.id
    )
    |> Repo.all()
    |> Enum.map(&Map.drop(Map.from_struct(&1), [:__meta__]))
  end

  defp opts(:operator, _f, extra), do: [mode: :merge] ++ extra

  defp opts(mode, f, extra) do
    System.put_env("BARKPARK_IMPORT_CONFINEMENT", Atom.to_string(mode))
    [mode: :merge, confine: true, grant_admin_to: {f.importer.id, "api_token"}] ++ extra
  end

  # Import over the target and prove no request came from the import.
  defp import_over!(f, mode, extra \\ []) do
    held = requests(f)
    assert {:ok, stats} = WorkspaceBundle.import_bundle(f.bundle, opts(mode, f, extra))

    assert requests(f) == held,
           "#{mode}: the import changed the target's access requests"

    assert stats.access_requests_left_out == 1
    stats
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

  defp seat_role(f) do
    case TenancyAuth.membership(f.u.id, f.ws.id, :user) do
      nil -> nil
      seat -> seat.role
    end
  end

  defp approve!(f, role),
    do: assert({:ok, _} = AccessRequests.approve(f.ws.id, f.rid, role, f.approver))

  defp to_role!(f, role),
    do: assert({:ok, _} = Members.update_role(f.ws.id, %{type: :user, id: f.u.id}, role))

  for mode <- @modes do
    @mode mode

    describe "merge import, #{mode}" do
      test "a request the target denied stays denied" do
        f = fixture()
        assert {:ok, _} = AccessRequests.deny(f.ws.id, f.rid, f.approver)
        import_over!(f, @mode)
        assert Repo.get!(AccessRequest, f.rid).status == "denied"
        assert seat_role(f) == nil
      end

      test "approved as member: nothing goes back to pending" do
        f = fixture()
        approve!(f, "member")
        import_over!(f, @mode)
        assert Repo.get!(AccessRequest, f.rid).status == "approved"
        assert seat_role(f) == "member"
      end

      test "approved into a lower custom role: nothing goes back to pending" do
        f = fixture()
        approve!(f, "bottom")
        import_over!(f, @mode)
        assert Repo.get!(AccessRequest, f.rid).status == "approved"
        assert seat_role(f) == "bottom"
      end

      test "approved, then re-roled A->B->A: nothing goes back to pending" do
        f = fixture()
        approve!(f, "member")
        to_role!(f, "contributor")
        to_role!(f, "member")
        import_over!(f, @mode)
        assert Repo.get!(AccessRequest, f.rid).status == "approved"
      end

      test "approved, then the seat removed: no request comes back" do
        f = fixture()
        approve!(f, "member")
        assert {:ok, _} = Members.remove_member(f.ws.id, %{type: :user, id: f.u.id})
        import_over!(f, @mode)
        assert Repo.get!(AccessRequest, f.rid).status == "approved"
        assert seat_role(f) == nil
      end

      test "withdrawn in the target: the import does not create it again" do
        f = fixture()
        assert {:ok, _} = AccessRequests.withdraw(f.u.id, f.rid)
        import_over!(f, @mode)
        assert Repo.get(AccessRequest, f.rid) == nil
      end

      test "still pending in the target: left exactly as it is" do
        f = fixture()
        import_over!(f, @mode)
        assert Repo.get!(AccessRequest, f.rid).status == "pending"
      end

      test "the seat changed after the import: still no request from the import" do
        f = fixture()
        assert {:ok, _} = AccessRequests.deny(f.ws.id, f.rid, f.approver)
        import_over!(f, @mode)

        assert {:ok, _} =
                 Members.add_user_member(f.ws.id, f.u.email, "member",
                   actor: f.approver,
                   consented: true
                 )

        to_role!(f, "contributor")
        assert Repo.get!(AccessRequest, f.rid).status == "denied"
        assert AccessRequests.list_pending(f.ws.id) == []
      end

      test "a bundle row dated in the future is not carried" do
        future = DateTime.add(DateTime.utc_now(), 365 * 24 * 3600, :second)

        f =
          fixture(fn f ->
            from(r in AccessRequest, where: r.id == ^f.rid)
            |> Repo.update_all(set: [inserted_at: future, updated_at: future])
          end)

        assert {:ok, _} = AccessRequests.withdraw(f.u.id, f.rid)
        import_over!(f, @mode)
        assert Repo.get(AccessRequest, f.rid) == nil
        assert AccessRequests.list_pending(f.ws.id) == []
      end
    end

    describe "clean import, #{mode}" do
      test "restoring a deleted workspace brings back no access request" do
        f = fixture()
        assert {:ok, _} = Tenancy.delete_workspace(f.ws)
        drop_audit_rows!(f.ws.id)
        assert requests(f) == []

        clean =
          case @mode do
            :operator -> []
            mode -> opts(mode, f, []) |> Keyword.delete(:mode)
          end

        assert {:ok, stats} = WorkspaceBundle.import_bundle(f.bundle, clean)
        assert requests(f) == []
        assert AccessRequests.list_pending(f.ws.id) == []
        assert stats.access_requests_left_out == 1
      end
    end
  end

  test "a bundle with no access requests reports none left out" do
    ws = create_workspace!("bar-none-#{System.unique_integer([:positive])}")
    _ = create_project!(ws)
    _ = token!(ws, "admin")
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    assert {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
    assert stats.access_requests_left_out == 0
  end

  test "a dataset remap import never carries access requests either" do
    assert {:workspace_scoped, "workspace_access_requests"} =
             DatasetRemap.member_class("workspace_access_requests")
  end
end
