defmodule Barkpark.Tenancy.SeatChangeTest do
  @moduledoc """
  The seat change stamp (task-018e79d8734a1b08): every write to a
  `workspace_memberships` row, by any writer, gets a new random stamp from the
  database, and a value the writer supplies is overwritten. The workspace
  import turns user triggers off and `LocalOnly.disable_user_triggers!/2` turns
  this one back on by name; a test below proves it fires there.

  async: false, because the trigger tests run `ALTER TABLE` on the shared
  memberships table inside the sandbox transaction.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.{Membership, Members}
  alias Barkpark.Tenancy.WorkspaceBundle.LocalOnly

  @supplied "00000000-0000-0000-0000-000000000001"
  @supplied_too "00000000-0000-0000-0000-000000000002"

  setup do
    ws = create_workspace!()
    %{ws: ws, ws_id: Ecto.UUID.dump!(ws.id)}
  end

  defp dump(nil), do: nil
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  defp insert_seat!(ws_id, supplied) do
    %{rows: [[stamp]]} =
      Repo.query!(
        "INSERT INTO workspace_memberships " <>
          "(id, workspace_id, principal_type, principal_id, role, seat_change, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), $1, 'user', gen_random_uuid(), 'member', " <>
          "COALESCE($2, gen_random_uuid()), now(), now()) RETURNING seat_change",
        [ws_id, dump(supplied)]
      )

    Ecto.UUID.load!(stamp)
  end

  defp update_seats!(ws_id, supplied) do
    Repo.query!(
      "UPDATE workspace_memberships SET role = 'admin', seat_change = $2 " <>
        "WHERE workspace_id = $1 RETURNING seat_change",
      [ws_id, dump(supplied)]
    ).rows
    |> Enum.map(fn [stamp] -> Ecto.UUID.load!(stamp) end)
  end

  defp trigger_state do
    %{rows: [[state]]} =
      Repo.query!(
        "SELECT tgenabled FROM pg_trigger WHERE tgname = 'workspace_memberships_seat_change'",
        []
      )

    state
  end

  # The engine's own statement (`alter_user_triggers!/2` is private to it).
  defp alter_user_triggers!(names, action) do
    Enum.each(names, &Repo.query!("ALTER TABLE public.#{&1} #{action} TRIGGER USER", []))
  end

  test "the trigger is ENABLE ALWAYS" do
    assert trigger_state() == "A"
  end

  test "a raw SQL insert gets a new stamp; the one it supplies is overwritten", %{ws_id: ws_id} do
    a = insert_seat!(ws_id, @supplied)
    b = insert_seat!(ws_id, @supplied)
    assert a != @supplied and b != @supplied and a != b
  end

  test "a raw SQL update gets a new stamp, also when it supplies the old one", %{ws_id: ws_id} do
    s = insert_seat!(ws_id, nil)
    assert [t] = update_seats!(ws_id, s)
    assert t != s
    assert [u] = update_seats!(ws_id, t)
    assert u not in [s, t]
  end

  test "the roster's own writes get new stamps and the struct reads them back", %{ws: ws} do
    {:ok, user} =
      Barkpark.Accounts.register_user(%{
        email: "seat-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    {:ok, seat} = TenancyAuth.create_membership(ws.id, user.id, "contributor", "user")
    assert {:ok, _} = Ecto.UUID.cast(seat.seat_change)
    assert Repo.get!(Membership, seat.id).seat_change == seat.seat_change

    {:ok, _} = Members.update_role(ws.id, %{type: :user, id: user.id}, "member")
    assert Repo.get!(Membership, seat.id).seat_change != seat.seat_change
  end

  test "after DISABLE TRIGGER USER, a value supplied to a seat row sticks (the control)",
       %{ws_id: ws_id} do
    alter_user_triggers!(["workspace_memberships"], "DISABLE")
    assert insert_seat!(ws_id, @supplied) == @supplied
    assert update_seats!(ws_id, @supplied_too) == [@supplied_too]
  end

  test "the import's trigger switches keep the seat trigger on, ENABLE ALWAYS", %{ws_id: ws_id} do
    tables = ["documents", "workspace_memberships"]

    Repo.transaction(fn ->
      :ok = LocalOnly.disable_user_triggers!(tables, &alter_user_triggers!/2)
      assert trigger_state() == "A"

      s = insert_seat!(ws_id, @supplied)
      assert s != @supplied
      assert [t] = update_seats!(ws_id, @supplied_too)
      assert t not in [s, @supplied_too]

      :ok = LocalOnly.enable_user_triggers!(tables, &alter_user_triggers!/2)
      # `ENABLE TRIGGER USER` alone would leave it plain enabled ("O").
      assert trigger_state() == "A"
    end)
  end

  test "under session_replication_role = replica a seat write still gets a new stamp",
       %{ws_id: ws_id} do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica", [])
      s = insert_seat!(ws_id, @supplied)
      assert s != @supplied
      assert [t] = update_seats!(ws_id, @supplied_too)
      assert t not in [s, @supplied_too]
    end)
  end
end
